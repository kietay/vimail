import Foundation
import MailCore
import MailStore

/// What `T` proposes for a rule made from an email (design §5.2).
public enum RuleSuggestion {
    /// Domains anyone can have an address at: sharing one with a sender says nothing.
    public static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "icloud.com", "me.com",
        "yahoo.com", "proton.me", "protonmail.com", "hey.com", "fastmail.com",
    ]

    /// Addresses programs send from, before any "+tag".
    static let automatedLocalParts: Set<String> = [
        "notifications", "notification", "notify", "alerts", "alert", "mailer-daemon", "bounce", "bounces",
        "receipts", "billing", "invoices", "orders", "updates", "news", "newsletter", "digest", "automated",
    ]

    /// "stripe.com" for "Receipts@Stripe.com"; "" without an "@".
    public static func domain(of address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return address[address.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func isConsumerDomain(_ domain: String) -> Bool {
        consumerDomains.contains(domain.lowercased())
    }

    /// Mail a program sent: list mail (it has an unsubscribe header), or a noreply-style address
    /// ("no-reply@", "notifications@", "receipts@").
    public static func isAutomated(_ sender: EmailAddress, isList: Bool) -> Bool {
        if isList { return true }
        let address = sender.normalized
        guard let at = address.lastIndex(of: "@") else { return false }
        var local = String(address[..<at])
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        let compact = local.filter { !"-_.".contains($0) }
        return compact.contains("noreply") || compact.contains("donotreply") || automatedLocalParts.contains(local)
    }

    /// The WHEN a rule made from an email starts with. Limited to the sender (offered for automated
    /// senders): `from:@stripe.com`. Else, when your own domain is not a consumer one,
    /// `-from:@studio.co`, so your colleagues' mail stays out, unless the email came from your domain
    /// itself. Else nothing.
    /// - Parameter account: your address.
    public static func when(account: String, sender: EmailAddress, onlySender: Bool) -> String {
        let theirs = domain(of: sender.email)
        if onlySender, !theirs.isEmpty { return "from:@\(theirs)" }
        let yours = domain(of: account)
        guard !yours.isEmpty, !isConsumerDomain(yours), theirs != yours, !theirs.hasSuffix(".\(yours)") else { return "" }
        return "-from:@\(yours)"
    }

    /// A name for a new label: the sender's organization ("Stripe" for receipts@mail.stripe.com), or
    /// for a person writing from a consumer address, their name.
    public static func labelName(for sender: EmailAddress) -> String {
        let domain = domain(of: sender.email)
        if isConsumerDomain(domain) { return sender.name.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        var parts = domain.split(separator: ".").map(String.init)
        guard parts.count > 1 else { return "" }
        parts.removeLast()
        // "bbc.co.uk": "co" belongs to the suffix.
        if parts.count > 1, let last = parts.last, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(last) { parts.removeLast() }
        guard let name = parts.last, !name.isEmpty else { return "" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

extension PreviewRow {
    /// The row's mark (design §5.3): ✔ match, ✖ no match, ~ unsure (not applied), ≠ disagrees with
    /// your labelling, ◐ judged before your newest marks, ! declined, ◌ not judged yet (or on its way
    /// to Claude). ● for your own marks is shown beside it.
    public var glyph: String {
        if testing { return "◌" }
        if disagrees { return "≠" }
        if judgedBeforeNewestMarks, source == .cache || source == .claude { return "◐" }
        switch outcome {
        case .match: return "✔"
        case .noMatch, .filteredOut: return "✖"
        case .unsure: return "~"
        case .declined: return "!"
        case .notJudged: return "◌"
        }
    }

    /// The line under the sender and subject: Claude's reason, or what decided the row.
    public var detail: String {
        if testing { return "testing…" }
        let reason = self.reason.flatMap { $0.isEmpty ? nil : $0 }
        let claude = source == .claude || source == .cache
        if disagrees {
            switch source {
            case .gate?: return "it has the label, but WHEN does not pass"
            case .override?: return "it has the label; your sender rule says never"
            default: return "you labeled this; Claude: \(verdictText)" + (reason.map { " · \($0)" } ?? "")
            }
        }
        if claude {
            let said = outcome == .declined ? "Claude declined to classify this email (often phishing)" : reason ?? "Claude: \(verdictText)"
            return judgedBeforeNewestMarks ? "judged before your newest mark · \(said)" : said
        }
        switch source {
        case .gate?: return outcome == .filteredOut ? "WHEN does not pass here" : "passes WHEN"
        case .mark?: return outcome == .match ? "you added the label" : "you removed the label"
        case .example?: return outcome == .match ? "your ✔" : "your ✖"
        case .override?: return outcome == .match ? "your sender rule: always" : "your sender rule: never"
        case .thread?: return "matched earlier in the conversation"
        case .claude?, .cache?, nil: return "not judged yet · ⌃r tests it"
        }
    }

    var verdictText: String {
        switch outcome {
        case .match: "match"
        case .noMatch, .filteredOut: "no match"
        case .unsure: "unsure"
        case .declined: "declined"
        case .notJudged: "not judged"
        }
    }
}

extension PreviewRow.Outcome {
    /// A decision on the message: Claude's or yours. Not "not judged yet", nor kept out by WHEN.
    public var isVerdict: Bool {
        switch self {
        case .match, .noMatch, .unsure, .declined: true
        case .notJudged, .filteredOut: false
        }
    }
}

/// The rule editor's lines (design §5.3).
public enum RuleEditorText {
    /// The preview's glyphs in the order the header counts them.
    static let glyphOrder = ["✔", "✖", "~", "≠", "◐", "!", "◌"]
    /// "Too broad?" shows when the rule would label more than this share of the mail in scope.
    public static let broadShare = 0.5

    /// "PREVIEW 31 · 9✔ 17✖ 2~ 1≠ 2◌ · Haiku 5.5": each row counts once, under its glyph.
    /// - Parameter decidedBy: the model's name, or "filter · free".
    public static func header(_ rows: [PreviewRow], decidedBy: String) -> String {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.glyph, default: 0] += 1 }
        let tally = glyphOrder.compactMap { glyph in counts[glyph].map { "\($0)\(glyph)" } }.joined(separator: " ")
        return (["PREVIEW \(rows.count)", tally, decidedBy].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    /// About what share of the mail in scope the rule would label: the share that passes WHEN and,
    /// for a Claude rule, of the newest passing mail in the sample that Claude or you decided, the
    /// share that matches. nil while that is not known.
    public static func breadth(passing: Int, inScope: Int, rows: [PreviewRow], asksClaude: Bool) -> Double? {
        guard inScope > 0 else { return nil }
        let pass = Double(passing) / Double(inScope)
        guard asksClaude else { return pass }
        let decided = rows.filter { $0.section == .recent && !$0.testing && $0.outcome.isVerdict }
        guard !decided.isEmpty else { return nil }
        return pass * Double(decided.filter { $0.outcome == .match }.count) / Double(decided.count)
    }

    /// "1,940 of 2,310 (90 d) pass · free".
    public static func freeCount(passing: Int, inScope: Int, days: Int) -> String {
        "\(RuleText.count(passing)) of \(RuleText.count(inScope)) (\(days) d) pass · free"
    }

    /// "✔2 ✖1 tested · 1 untested mark": your marks, and whether the last test used them. A filter
    /// rule's marks only decide their own messages: "✔2 ✖1 marked".
    /// - Parameter tested: the messages of the example set the last test used (`promptExampleIDs`).
    public static func teach(_ examples: [RuleExample], tested: [String], asksClaude: Bool = true) -> String {
        guard !examples.isEmpty else { return "no marks yet · y ✔ and n ✖ in the preview" }
        guard asksClaude else { return "✔\(examples.filter(\.matches).count) ✖\(examples.filter { !$0.matches }.count) marked" }
        let set = Set(tested)
        let used = examples.filter { set.contains($0.messageID) }
        let untested = examples.count - used.count
        var parts: [String] = []
        if !used.isEmpty { parts.append("✔\(used.filter(\.matches).count) ✖\(used.filter { !$0.matches }.count) tested") }
        if untested > 0 { parts.append(untested == 1 ? "1 untested mark" : "\(untested) untested marks") }
        return parts.joined(separator: " · ")
    }

    /// The marks the last test did not use.
    public static func untested(_ examples: [RuleExample], tested: [String]) -> Int {
        let set = Set(tested)
        return examples.filter { !set.contains($0.messageID) }.count
    }

    /// "⌃r test 12 ≈ $0.15 · ⌃R all 27 ≈ $0.34", or what there is to test.
    public static func testPrices(atIssue: PreviewCost, all: PreviewCost) -> String {
        guard all.calls > 0 else { return "nothing to test: your marks and Claude decide every row" }
        var parts: [String] = []
        if atIssue.calls > 0 { parts.append("⌃r test \(atIssue.calls) ≈ \(Dollars.text(atIssue.micros))") }
        parts.append("⌃R all \(all.calls) ≈ \(Dollars.text(all.micros))")
        return parts.joined(separator: " · ")
    }

    /// "preview today $0.22 of $1.00".
    public static func previewSpend(today: Int64, allowance: Int64) -> String {
        "preview today \(Dollars.text(today)) of \(Dollars.text(allowance))"
    }

    /// Why a test stopped, for the editor.
    public static func stopped(_ error: PreviewError) -> String {
        switch error {
        case .budget(.previewRoom): "Today's preview allowance is spent. WHEN previews keep working; tests continue tomorrow."
        case .budget(.runRoom): "Claude spend is at what live mail needs today. WHEN previews keep working."
        case .budget(.day): "Today's Claude budget is spent. WHEN previews keep working."
        case .budget(.month): "This month's Claude budget is spent. WHEN previews keep working."
        case .paused(let reason): "Claude can't test now: \(pauseText(reason)). WHEN previews keep working."
        }
    }

    /// What to do about a Claude pause: "add an API key in Settings".
    public static func pauseText(_ reason: PauseReason) -> String {
        switch reason {
        case .noKey: "add an API key in Settings"
        case .noConsent: "allow Claude for this account"
        case .badKey: "Anthropic rejected the API key"
        case .billing: "the API account needs credit"
        case .budgetDay: "today's budget is spent"
        case .budgetMonth: "this month's budget is spent"
        case .modelUnavailable: "the model is not available; pick another in Settings"
        case .apiIncompatible: "the API changed; update vimail"
        }
    }
}

/// Counts, days and money as the rules screens show them.
public enum RuleText {
    /// "1,940".
    public static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// "9 Oct".
    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    /// "9–14 Oct" within one month, else "28 Sep–3 Oct".
    public static func days(_ interval: DateInterval) -> String {
        let calendar = Calendar.current
        let start = interval.start
        let end = interval.end
        if calendar.isDate(start, inSameDayAs: end) { return day(start) }
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(calendar.component(.day, from: start))–\(day(end))"
        }
        return "\(day(start))–\(day(end))"
    }
}
