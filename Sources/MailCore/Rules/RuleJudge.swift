import Foundation

/// Decides Claude rules for one email. `ClaudeJudge` (MailAI) owns the rate limiter, the spend
/// reservation, the call and its settlement; the engine sees verdicts or a typed error.
public protocol RuleJudge: Sendable {
    func judge(_ request: JudgeRequest) async throws(JudgeError) -> JudgeResponse
}

/// Whose budget a call spends.
public enum SpendLane: Sendable, Hashable {
    /// Newly arrived mail.
    case live
    /// An approved run over stored mail, by run ID.
    case run(Int64)
    /// The rule editor: previews and drafting.
    case preview
}

/// How long Claude keeps the cached prompt prefix (rules and examples).
public enum PromptCacheTTL: String, Sendable, Hashable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

/// One active Claude rule, as the prompt lists it.
public struct JudgeRule: Sendable, Hashable {
    public var key: String
    /// The target label's current name.
    public var labelName: String
    public var ask: String

    public init(key: String, labelName: String, ask: String) {
        self.key = key
        self.labelName = labelName
        self.ask = ask
    }
}

/// A ✔ or ✖ the person gave one rule. Only the sender name, domain and subject travel.
public struct JudgeExample: Sendable, Hashable {
    public var ruleKey: String
    /// `.match` or `.noMatch`.
    public var verdict: Verdict
    /// "Figma via Stripe · @stripe.com · Your receipt from Figma #4821-3390" (`digest(of:selfAddresses:)`).
    public var digest: String

    public init(ruleKey: String, verdict: Verdict, digest: String) {
        self.ruleKey = ruleKey
        self.verdict = verdict
        self.digest = digest
    }

    public static let subjectLimit = 120

    /// Sender name, sender domain and subject (at most `subjectLimit` characters), prompt-safe. The
    /// account's own addresses read "me", as in `EmailDigest`.
    /// - Parameter selfAddresses: the account's address and aliases, lowercased.
    public static func digest(of message: MailMessage, selfAddresses: Set<String>) -> String {
        let name = message.from.name.map { EmailDigest.redacting(selfAddresses, in: HTMLText.promptLine($0)) } ?? ""
        let domain = message.from.normalized.split(separator: "@").last.map { "@" + HTMLText.promptLine(String($0)) } ?? ""
        let subject = HTMLText.truncated(EmailDigest.redacting(selfAddresses, in: HTMLText.promptLine(message.subject)), to: subjectLimit)
        return [name, domain, subject].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One call's worth of work: the rules to decide for one email.
public struct JudgeRequest: Sendable, Hashable {
    public var lane: SpendLane
    /// Every active Claude rule, sorted by key. It forms the cached system prompt and the output
    /// schema's enum, so it is the same for every email until the rules change.
    public var catalog: [JudgeRule]
    /// Keys of the rules to decide for this email, in catalog order.
    public var evaluate: [String]
    /// Examples for the catalog's rules. Cached with the rules, so the same for every email.
    public var examples: [JudgeExample]
    public var email: EmailDigest
    public var cacheTTL: PromptCacheTTL

    /// Sorts the catalog by key and keeps only `evaluate` keys that are in it.
    /// - Parameter cacheTTL: defaults to an hour for live mail (arrivals are minutes apart) and five
    ///   minutes for previews and runs (calls follow each other closely).
    public init(lane: SpendLane, catalog: [JudgeRule], evaluate: [String], examples: [JudgeExample], email: EmailDigest, cacheTTL: PromptCacheTTL? = nil) {
        self.lane = lane
        self.catalog = catalog.sorted { Self.keyOrder($0.key, $1.key) }
        let wanted = Set(evaluate)
        self.evaluate = self.catalog.map(\.key).filter(wanted.contains)
        self.examples = examples
        self.email = email
        self.cacheTTL = cacheTTL ?? (lane == .live ? .oneHour : .fiveMinutes)
    }

    /// "r2" before "r10".
    static func keyOrder(_ a: String, _ b: String) -> Bool {
        a.count != b.count ? a.count < b.count : a < b
    }
}

/// Claude's answer for one email.
public struct JudgeResponse: Sendable, Hashable {
    public struct Decision: Sendable, Hashable {
        public var verdict: Verdict
        /// At most 15 plain words naming the deciding evidence. Shown by "why these labels?", never logged.
        public var reason: String

        public init(verdict: Verdict, reason: String) {
            self.verdict = verdict
            self.reason = reason
        }
    }

    /// One decision per requested rule key.
    public var decisions: [String: Decision]
    /// The model asked for.
    public var model: String
    /// The model that answered: another one after a server-side fallback.
    public var servedBy: String
    /// What the call cost, in millionths of a dollar.
    public var costMicros: Int64
    public var usage: TokenUsage

    public init(decisions: [String: Decision], model: String, servedBy: String, costMicros: Int64, usage: TokenUsage) {
        self.decisions = decisions
        self.model = model
        self.servedBy = servedBy
        self.costMicros = costMicros
        self.usage = usage
    }
}

/// Tokens billed for one call, summed over fallback attempts.
public struct TokenUsage: Sendable, Hashable {
    public var input: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// Why a judge call produced no verdicts.
public enum JudgeError: Error, Sendable, Hashable {
    /// Rate limited, overloaded or a server error. Retry after the delay (the server's, when it gave one).
    case transient(retryAfter: Duration?)
    /// No network. Not counted as an attempt.
    case offline
    /// Claude can't be used until the person acts: key, consent, billing, budget or model.
    case paused(PauseReason)
    /// The call would cross a budget.
    case budget(BudgetStop)
    /// Claude declined to classify this email (often phishing). Becomes `declined`, never retried.
    case refused(category: String?)
    /// The answer was cut off or incomplete.
    case truncated
    /// A request Claude rejects for this email only, or an answer that doesn't parse ("http_413").
    case invalid(code: String)
    /// Claude answered and billed one or more attempts, then the call still ended in `error` (a
    /// refusal, an answer cut off or unreadable, a retry that failed). The cost counts toward the
    /// run and its cap like an answer's.
    indirect case billed(JudgeError, costMicros: Int64)
}

extension JudgeError {
    /// The error itself, without what Claude billed for it.
    public var unbilled: JudgeError {
        if case .billed(let error, _) = self { error.unbilled } else { self }
    }

    /// What Claude billed before the call failed.
    public var billedMicros: Int64 {
        if case .billed(let error, let cost) = self { cost + error.billedMicros } else { 0 }
    }
}

/// Which budget a call would cross.
public enum BudgetStop: Sendable, Hashable {
    case day, month
    /// Runs leave today's and this month's reserve for live mail.
    case runRoom
    /// The editor's own daily allowance.
    case previewRoom
}

/// Why Claude rules are paused for the whole app or account. Filter-only rules keep running.
public enum PauseReason: String, Sendable, Codable {
    case noKey, noConsent, badKey, billing, budgetDay, budgetMonth, modelUnavailable, apiIncompatible
}
