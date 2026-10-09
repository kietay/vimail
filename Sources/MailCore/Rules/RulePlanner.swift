import Foundation

/// The ordered pass of one message through the rules.
///
/// Rules fold in order over a working label set, so a rule's `label:` terms see what earlier rules
/// add, and a match of a stop-after-match rule ends the pass. The fold is three-valued: each rule is
/// decided (matched or not), skipped after a stop, or pending while a verdict it depends on is
/// missing: its own ASK, an earlier rule that may add a label it tests, or an earlier stop-after-match
/// rule that may end the pass.
///
/// The same fold is the pre-pass (before Claude: `needsVerdict` lists the rules to ask about) and
/// the final pass (with every verdict known). Rules that wait on nothing are decided either way, so
/// filter rules still apply while Claude is unavailable.
public enum RulePlanner {
    /// One enabled rule, in position order, as it stands for one message.
    public struct Input: Sendable, Hashable {
        public var ruleID: String
        /// The rule has an ASK, so without a decision it needs Claude.
        public var asks: Bool
        public var stopAfterMatch: Bool
        /// Label IDs THEN adds.
        public var adds: [String]
        /// In scope and passing WHEN apart from its label terms (tested in SQL).
        public var gate: Bool
        /// WHEN's `label:` and `-label:` terms, tested here against the working labels.
        public var labelConditions: [LabelCondition]
        /// Already known for this rule and message: a label mark, an example, a sender override,
        /// an inherited match, a cached verdict or Claude's answer. Without an ASK, nil means "match".
        public var decision: Verdict?

        public init(ruleID: String, asks: Bool, stopAfterMatch: Bool = false, adds: [String], gate: Bool, labelConditions: [LabelCondition] = [], decision: Verdict? = nil) {
            self.ruleID = ruleID
            self.asks = asks
            self.stopAfterMatch = stopAfterMatch
            self.adds = adds
            self.gate = gate
            self.labelConditions = labelConditions
            self.decision = decision
        }

        public init(rule: Rule, gate: Bool, labelConditions: [LabelCondition] = [], decision: Verdict? = nil) {
            self.init(
                ruleID: rule.id, asks: rule.asksClaude, stopAfterMatch: rule.stopAfterMatch, adds: rule.labelTargets.map(\.id),
                gate: gate, labelConditions: labelConditions, decision: decision
            )
        }
    }

    /// A resolved `label:` term.
    public struct LabelCondition: Sendable, Hashable {
        /// Every label with the term's name (`RuleFilter.LabelTerm.labelIDs(in:)`).
        public var labelIDs: Set<String>
        /// `-label:`: the label must be absent.
        public var negated: Bool

        public init(labelIDs: Set<String>, negated: Bool = false) {
            self.labelIDs = labelIDs
            self.negated = negated
        }
    }

    /// Folds `rules` (in position order) over a message that carries `labels`.
    public static func plan(_ rules: [Input], labels: Set<String>) -> RulePlan {
        // Labels present for sure, and labels a pending rule may still add.
        var certain = labels
        var possible = labels
        var reached = Tri.yes
        var steps: [RulePlan.Step] = []
        var needsVerdict: [String] = []
        var stoppedBy: String?

        for rule in rules {
            guard reached != .no else {
                steps.append(RulePlan.Step(ruleID: rule.ruleID, outcome: .skipped, labels: certain))
                continue
            }
            let labelTerms = rule.gate ? evaluate(rule.labelConditions, certain: certain, possible: possible) : .no
            if rule.asks, rule.decision == nil, labelTerms != .no { needsVerdict.append(rule.ruleID) }

            let matches: Tri
            if labelTerms == .no {
                matches = .no
            } else if let decision = rule.decision {
                matches = decision.isMatch ? labelTerms : .no
            } else {
                matches = rule.asks ? .unknown : labelTerms
            }

            var step = RulePlan.Step(ruleID: rule.ruleID, outcome: .notMatched, labels: certain)
            switch (matches, reached) {
            case (.no, _):
                break
            case (.yes, .yes):
                step.outcome = .matched
                step.added = Set(rule.adds).subtracting(certain)
                certain.formUnion(rule.adds)
                possible.formUnion(rule.adds)
                step.labels = certain
                if rule.stopAfterMatch {
                    reached = .no
                    stoppedBy = rule.ruleID
                }
            default:
                step.outcome = .pending
                possible.formUnion(rule.adds)
                if rule.stopAfterMatch { reached = .unknown }
            }
            steps.append(step)
        }
        return RulePlan(steps: steps, needsVerdict: needsVerdict, stoppedBy: stoppedBy)
    }

    enum Tri {
        case yes, no, unknown

        var negated: Tri {
            switch self {
            case .yes: .no
            case .no: .yes
            case .unknown: .unknown
            }
        }
    }

    /// All terms must hold: present, absent, or depending on a pending rule's add.
    static func evaluate(_ conditions: [LabelCondition], certain: Set<String>, possible: Set<String>) -> Tri {
        var result = Tri.yes
        for condition in conditions {
            let present: Tri = !condition.labelIDs.isDisjoint(with: certain) ? .yes
                : !condition.labelIDs.isDisjoint(with: possible) ? .unknown : .no
            switch condition.negated ? present.negated : present {
            case .no: return .no
            case .unknown: result = .unknown
            case .yes: break
            }
        }
        return result
    }
}

/// The result of `RulePlanner.plan`.
public struct RulePlan: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case matched
        /// Out of scope, filtered out, or decided no (`no_match`, `unsure`, `declined`, a removal mark).
        case notMatched
        /// An earlier rule's match ended the pass.
        case skipped
        /// Waits for a missing verdict: its own, or one an earlier rule needs.
        case pending
    }

    public struct Step: Sendable, Hashable {
        public var ruleID: String
        public var outcome: Outcome
        /// Labels this match added that the working set did not have yet. Empty when another rule
        /// (or the person) added them first: the rule then co-owns them.
        public var added: Set<String> = []
        /// The working labels after this rule (pending adds not included).
        public var labels: Set<String>
    }

    /// One per input rule, in order.
    public var steps: [Step]
    /// Rules to ask Claude about: an ASK, no decision yet, and a gate and label terms that pass or
    /// may pass. In rule order.
    public var needsVerdict: [String]
    /// The stop-after-match rule whose match ended the pass.
    public var stoppedBy: String?

    /// No rule waits for a verdict, so the plan can be committed whole.
    public var isComplete: Bool { !steps.contains { $0.outcome == .pending } }
    /// Matched rules in order.
    public var matched: [String] { steps.filter { $0.outcome == .matched }.map(\.ruleID) }
    /// Every label the matches add.
    public var labelAdds: Set<String> { steps.reduce(into: []) { $0.formUnion($1.added) } }
}
