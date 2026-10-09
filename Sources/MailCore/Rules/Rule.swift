import Foundation

/// A rule: which mail it looks at (WHEN, search syntax tested per message), an optional question
/// Claude decides (ASK), and what happens on a match (THEN). Rules run in order over each message.
///
/// Rules are stored per account as JSON and decode leniently: missing fields take their defaults, and
/// actions and scopes from a newer build are kept as `.unsupported`, which stops the rule from running.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = Rule.currentSchemaVersion
    /// "r_8f2a1c3d".
    public let id: String
    /// "r7": names the rule in prompts and in Claude's output schema. Never reused.
    public let key: String
    /// Cosmetic: renaming keeps the revision.
    public var name: String
    public var enabled: Bool
    /// Goes up by one when WHEN, ASK, THEN, scope or stop-after-match change (`changesSemantics(from:)`).
    public var revision: Int
    /// Search syntax tested against one message (`RuleFilter`). "" matches everything in scope.
    public var when: String
    /// What Claude decides, in the person's words. nil for a rule that only filters.
    public var ask: String?
    /// The ASK was drafted from an email. Cleared once the person edits it.
    public var askDrafted = false
    /// Phase 1: one `.addLabel`.
    public var then: [RuleAction]
    public var scope = RuleScope()
    /// A match ends the pass: later rules do not see the message.
    public var stopAfterMatch = false
    /// Removing a label this rule added also teaches Claude that the message does not match.
    public var editsTeach = true
    /// Opts out of the breaker that trips rules matching most new mail.
    public var acknowledgedBroad = false
    /// The examples last tested in the editor; the prompt uses these.
    public var promptExampleIDs: [String] = []

    public init(
        id: String = Rule.makeID(), key: String, name: String, enabled: Bool = true, revision: Int = 1,
        when: String = "", ask: String? = nil, then: [RuleAction], scope: RuleScope = RuleScope(), stopAfterMatch: Bool = false
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.enabled = enabled
        self.revision = revision
        self.when = when
        self.ask = ask
        self.then = then
        self.scope = scope
        self.stopAfterMatch = stopAfterMatch
    }

    public static func makeID() -> String { "r_\(UUID().uuidString.prefix(8).lowercased())" }

    /// True when Claude decides part of this rule.
    public var asksClaude: Bool { ask.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }

    /// The labels THEN adds.
    public var labelTargets: [LabelRef] {
        then.compactMap { if case .addLabel(let label) = $0 { label } else { nil } }
    }

    /// False when the rule came from a newer build: it is kept but never runs.
    public var isSupported: Bool {
        schemaVersion <= Self.currentSchemaVersion && scope.isSupported
            && !then.contains { if case .unsupported = $0 { true } else { false } }
    }

    /// True when this version decides differently from `previous`, so it needs a new revision.
    public func changesSemantics(from previous: Rule) -> Bool {
        when != previous.when || ask != previous.ask || then != previous.then
            || scope != previous.scope || stopAfterMatch != previous.stopAfterMatch
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, key, name, enabled, revision, when, ask, askDrafted, then, scope
        case stopAfterMatch, editsTeach, acknowledgedBroad, promptExampleIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Rule(id: "", key: "", name: "", then: [])
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        id = try container.decode(String.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        // A rule whose state is unknown stays off.
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? defaults.revision
        when = try container.decodeIfPresent(String.self, forKey: .when) ?? defaults.when
        ask = try container.decodeIfPresent(String.self, forKey: .ask)
        askDrafted = try container.decodeIfPresent(Bool.self, forKey: .askDrafted) ?? defaults.askDrafted
        then = try container.decodeIfPresent([RuleAction].self, forKey: .then) ?? defaults.then
        scope = try container.decodeIfPresent(RuleScope.self, forKey: .scope) ?? defaults.scope
        stopAfterMatch = try container.decodeIfPresent(Bool.self, forKey: .stopAfterMatch) ?? defaults.stopAfterMatch
        editsTeach = try container.decodeIfPresent(Bool.self, forKey: .editsTeach) ?? defaults.editsTeach
        acknowledgedBroad = try container.decodeIfPresent(Bool.self, forKey: .acknowledgedBroad) ?? defaults.acknowledgedBroad
        promptExampleIDs = try container.decodeIfPresent([String].self, forKey: .promptExampleIDs) ?? defaults.promptExampleIDs
    }
}

/// Which messages a rule looks at.
public struct RuleScope: Codable, Sendable, Hashable {
    /// Stored as `"received"` or `"inbox"`. A value this build does not know decodes to `.unsupported`
    /// with its JSON, and encodes back unchanged.
    public enum Mailboxes: Codable, Sendable, Hashable {
        /// Everything received: not Sent, Drafts, Spam or Trash. Archived mail included.
        case received
        case inbox
        case unsupported(json: String)

        public init(from decoder: any Decoder) throws {
            let raw = try JSONValue(from: decoder)
            switch raw.string {
            case "received": self = .received
            case "inbox": self = .inbox
            default: self = .unsupported(json: raw.encodedString)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            let value: JSONValue = switch self {
            case .received: .string("received")
            case .inbox: .string("inbox")
            case .unsupported(let json): (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null
            }
            try value.encode(to: encoder)
        }
    }

    public var mailboxes: Mailboxes = .received
    /// Opt-in: a reply matches without a Claude call when the rule matched its conversation.
    public var inheritInThread = false

    public init(mailboxes: Mailboxes = .received, inheritInThread: Bool = false) {
        self.mailboxes = mailboxes
        self.inheritInThread = inheritInThread
    }

    /// False when it came from a newer build.
    public var isSupported: Bool {
        if case .unsupported = mailboxes { false } else { true }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mailboxes = try container.decodeIfPresent(Mailboxes.self, forKey: .mailboxes) ?? .received
        inheritInThread = try container.decodeIfPresent(Bool.self, forKey: .inheritInThread) ?? false
    }
}

/// A label a rule targets, by ID. The name is only a fallback for display when the label is gone.
public struct LabelRef: Codable, Sendable, Hashable {
    public var id: String
    public var lastKnownName: String

    public init(id: String, lastKnownName: String) {
        self.id = id
        self.lastKnownName = lastKnownName
    }
}

/// What a matching rule does.
///
/// Stored as `{"type": "addLabel", "label": {...}}`. A type this build does not know decodes to
/// `.unsupported` with its JSON, and encodes back unchanged.
public enum RuleAction: Codable, Sendable, Hashable {
    case addLabel(LabelRef)
    case unsupported(type: String, json: String)

    public var risk: ActionRisk {
        if case .addLabel = self { .annotative } else { .outbound }
    }

    private enum CodingKeys: String, CodingKey { case type, label }

    public init(from decoder: any Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let type = raw["type"]?.string ?? ""
        if type == "addLabel", let label = try? raw["label"]?.decoded(as: LabelRef.self) {
            self = .addLabel(label)
        } else {
            self = .unsupported(type: type, json: raw.encodedString)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .addLabel(let label):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("addLabel", forKey: .type)
            try container.encode(label, forKey: .label)
        case .unsupported(let type, let json):
            let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object(["type": .string(type)])
            try value.encode(to: encoder)
        }
    }
}

/// How much an action can change, from labels (undoable, harmless) to anything that leaves the account.
public enum ActionRisk: Int, Sendable, Comparable {
    case annotative, visibility, destructive, outbound

    public static func < (a: ActionRisk, b: ActionRisk) -> Bool { a.rawValue < b.rawValue }
}

/// Claude's decision about one rule for one message. `unsure` and `declined` count as no match.
public enum Verdict: String, Codable, Sendable {
    case match
    case noMatch = "no_match"
    /// Partly fits or thin evidence. Not applied; queued for review.
    case unsure
    /// Claude refused to classify the message (often phishing).
    case declined

    public var isMatch: Bool { self == .match }
}

/// What changed in an account's rules, so the engine reloads them and adjusts runs using the rule.
public enum RuleChange: Sendable, Hashable {
    case created(ruleID: String)
    /// A new revision: WHEN, ASK, THEN, scope or stop-after-match changed. Runs using the rule pause.
    case revised(ruleID: String, revision: Int)
    /// Name, examples or switches that keep the revision.
    case updated(ruleID: String)
    case enabled(ruleID: String)
    /// Removed from its runs; its queued work is cancelled.
    case disabled(ruleID: String)
    case deleted(ruleID: String)
    case reordered
}

/// Any JSON value, so actions from a newer build survive a round trip unchanged.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    /// Compact JSON with sorted keys.
    var encodedString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
