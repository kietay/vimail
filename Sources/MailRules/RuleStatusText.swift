import Foundation
import MailCore

/// The rules segment of the status bar (design §5.5).
public struct RulesStatusLine: Sendable, Hashable {
    /// How the status bar colors it, least urgent first.
    public enum Tone: Int, Sendable, Hashable, Comparable {
        case normal
        /// Work under way.
        case busy
        /// Worth a look: a budget pause, failures, a rule turned off.
        case warning
        /// Claude can't work until you act: the key, billing, the model.
        case error

        public static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

extension RuleEngineStatus {
    /// What the status bar shows after the sync state, or nil when there is nothing to show.
    ///
    /// It starts with the most important state: `rules paused` (you paused them), `rules paused ·
    /// daily budget` (Claude is paused), `rules 84/100 · $1.06` (runs over stored mail), `rules 5 queued`
    /// (arrived mail), `rules 2 failed`, `rules 3 unsure`, or a bare `rules`. Notes follow: what waits
    /// for Claude, is held or paused, Gmail updates that failed and rules turned off (`rules · 740 held`).
    /// Claude without a key or consent is only shown while mail waits for it.
    /// - Parameter gmailRejected: labels from rules that Gmail refused since you last looked.
    public func statusLine(gmailRejected: Int = 0) -> RulesStatusLine? {
        var head = "rules"
        var notes: [String] = []
        var tone = RulesStatusLine.Tone.normal
        func note(_ text: String, _ level: RulesStatusLine.Tone = .normal) {
            notes.append(text)
            tone = max(tone, level)
        }

        let running = runs.filter { $0.state == .running }
        var shownQueued = false, shownWaiting = false, shownFailed = false, shownUnsure = false
        if userPaused {
            head = "rules paused"
        } else if case .paused(let reason) = ai, let pause = Self.pauseText(reason, waiting: waitingAI) {
            head = "rules paused"
            note(pause.text, pause.tone)
            if waitingAI > 0 { notes.append("\(waitingAI) waiting") }
            shownWaiting = true
        } else if !running.isEmpty {
            head = "rules \(running.reduce(0) { $0 + $1.done })/\(running.reduce(0) { $0 + $1.total })"
            note(Dollars.text(running.reduce(Int64(0)) { $0 + $1.costMicros }), .busy)
        } else if liveQueued > 0 {
            head = "rules \(liveQueued) queued"
            tone = .busy
            shownQueued = true
        } else if failed > 0 {
            head = "rules \(failed) failed"
            tone = .warning
            shownFailed = true
        } else if unsureToReview > 0 {
            head = "rules \(unsureToReview) unsure"
            shownUnsure = true
        }

        if liveQueued > 0, !shownQueued { note("\(liveQueued) queued") }
        if waitingAI > 0, !shownWaiting { note("\(waitingAI) waiting for Claude") }
        if failed > 0, !shownFailed { note("\(failed) failed", .warning) }
        if unsureToReview > 0, !shownUnsure { note("\(unsureToReview) unsure") }
        if held > 0 { note("\(held) held") }
        let stopped = runs.filter { $0.state == .paused && $0.pauseReason != .ai && $0.pauseReason != .budget }.count
        if stopped > 0 { note(stopped == 1 ? "1 run paused" : "\(stopped) runs paused", .warning) }
        if gmailRejected > 0 { note(gmailRejected == 1 ? "1 Gmail update failed" : "\(gmailRejected) Gmail updates failed", .warning) }
        let off = Set(tripped + labelMissing).count
        if off > 0 { note(off == 1 ? "1 rule turned off" : "\(off) rules turned off", .warning) }

        guard head != "rules" || !notes.isEmpty else { return nil }
        return RulesStatusLine(text: ([head] + notes).joined(separator: " · "), tone: tone)
    }

    /// Why Claude is paused, in the status bar. A missing key or consent only matters while mail waits.
    static func pauseText(_ reason: PauseReason, waiting: Int) -> (text: String, tone: RulesStatusLine.Tone)? {
        switch reason {
        case .budgetDay: ("daily budget", .warning)
        case .budgetMonth: ("monthly budget", .warning)
        case .badKey: ("check API key", .error)
        case .billing: ("add credit", .error)
        case .modelUnavailable: ("model unavailable", .error)
        case .apiIncompatible: ("API changed", .error)
        case .noKey: waiting > 0 ? ("add an API key", .error) : nil
        case .noConsent: waiting > 0 ? ("allow Claude in Settings", .warning) : nil
        }
    }
}

/// Money as rules show it, in the status bar, Settings and confirmations.
public enum Dollars {
    /// "$1.06" from millionths of a dollar; amounts under half a cent read "< $0.01".
    public static func text(_ micros: Int64) -> String {
        if micros > 0 && micros < 5_000 { return "< $0.01" }
        return String(format: "$%.2f", Double(micros) / 1_000_000)
    }

    /// An estimate: "≈ $0.23", "< $0.01" (never "≈ < $0.01"), "$0.00".
    public static func estimate(_ micros: Int64) -> String {
        micros < 5_000 ? text(micros) : "≈ \(text(micros))"
    }

    /// A monthly estimate: "≈ $0.23/mo", "< $0.01/mo", "$0.00/mo".
    public static func monthly(_ micros: Int64) -> String {
        "\(estimate(micros))/mo"
    }
}

extension LabelEditNote {
    /// The toast after you removed a label that rules had added:
    /// "receipts removed · rule Receipts won't re-add it and will learn from this". nil when no rule
    /// had added it.
    public func removalToast(labelName: String) -> String? {
        guard !stoppedRules.isEmpty else { return nil }
        var text = "\(labelName) removed · \(Self.rules(stoppedRules)) won't re-add it"
        if Set(taughtRules) == Set(stoppedRules) {
            text += " and will learn from this"
        } else if !taughtRules.isEmpty {
            text += " · \(Self.names(taughtRules)) will learn from this"
        }
        return text
    }

    /// The toast after `x` or `a` in "why these labels?" when the label was already like that:
    /// "receipts was already there · rule Receipts will learn from this". nil when no rule learned.
    public func unchangedToast(labelName: String, added: Bool) -> String? {
        guard !taughtRules.isEmpty else { return nil }
        return "\(labelName) was already \(added ? "there" : "off") · \(Self.rules(taughtRules)) will learn from this"
    }

    /// "rule Receipts", "rules Receipts and Travel".
    static func rules(_ names: [String]) -> String {
        (names.count == 1 ? "rule " : "rules ") + Self.names(names)
    }

    /// "Receipts", "Receipts and Travel", "A, B and C".
    static func names(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
