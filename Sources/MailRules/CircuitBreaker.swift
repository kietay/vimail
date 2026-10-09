import Foundation

/// Turns off a rule that runs away on live mail.
///
/// A rule trips when it adds more than 100 labels to messages dated within one hour, or matches more
/// than 80% of the last 40 messages in its scope (WHEN rejects count), unless you acknowledged that
/// it is broad. Counts go by message date, not by when the pass ran, so catching up on mail that
/// arrived while offline, over budget or without a working key does not trip it.
struct CircuitBreaker {
    enum Trip: String {
        /// Too many labels on mail dated within an hour.
        case burst
        /// Matches most mail.
        case ratio
    }

    static let burstLimit = 100
    static let burstWindow: TimeInterval = 3_600
    static let ratioSample = 40
    static let ratioLimit = 0.8
    /// Dates kept per rule for the burst count.
    static let keptAdds = 1_000

    /// Per rule: the messages it added its label to, by date, oldest first.
    private var adds: [String: [(messageID: String, date: Date)]] = [:]
    /// Per rule: the newest messages in its scope that it decided, oldest first.
    private var recent: [String: [(messageID: String, date: Date, matched: Bool)]] = [:]

    /// Records one live decision. A message counts once per rule: one that waited for Claude comes
    /// back for the rules still open, with the others decided again. Returns why the rule trips, if
    /// it does.
    /// - Parameters:
    ///   - added: the match added the label (it was not there already).
    ///   - broadAllowed: the rule's `acknowledgedBroad`: only a burst trips it.
    mutating func record(ruleID: String, messageID: String, date: Date, matched: Bool, added: Bool, broadAllowed: Bool) -> Trip? {
        var sample = recent[ruleID, default: []]
        guard !sample.contains(where: { $0.messageID == messageID }) else { return nil }
        if added, adds[ruleID]?.contains(where: { $0.messageID == messageID }) != true {
            var dates = adds[ruleID, default: []]
            dates.insert((messageID, date), at: dates.firstIndex { $0.date > date } ?? dates.endIndex)
            if dates.count > Self.keptAdds { dates.removeFirst(dates.count - Self.keptAdds) }
            adds[ruleID] = dates
            if Self.densest(dates.map(\.date)) > Self.burstLimit { return .burst }
        }
        sample.insert((messageID, date, matched), at: sample.firstIndex { $0.date > date } ?? sample.endIndex)
        if sample.count > Self.ratioSample { sample.removeFirst(sample.count - Self.ratioSample) }
        recent[ruleID] = sample
        let matches = sample.filter(\.matched).count
        if !broadAllowed, sample.count == Self.ratioSample, Double(matches) > Self.ratioLimit * Double(Self.ratioSample) { return .ratio }
        return nil
    }

    /// The most of `dates` (sorted) that fall within one `burstWindow`.
    static func densest(_ dates: [Date]) -> Int {
        var best = 0
        var start = 0
        for end in dates.indices {
            while dates[end].timeIntervalSince(dates[start]) >= burstWindow { start += 1 }
            best = max(best, end - start + 1)
        }
        return best
    }

    /// Starts the rule's counts over: after an edit, a re-enable or a trip.
    mutating func forget(_ ruleID: String) {
        adds[ruleID] = nil
        recent[ruleID] = nil
    }
}
