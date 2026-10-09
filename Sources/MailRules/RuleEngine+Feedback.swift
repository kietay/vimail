import Foundation
import MailCore
import MailStore

/// One edit of a label you made by hand (`perform`, `undo`, `redo` in the app).
public struct LabelEdit: Sendable, Hashable {
    /// Identifies the edit, so undoing it deletes the marks and examples it made.
    public var undoKey: String
    public var labelID: String
    /// You added the label (true) or removed it (false).
    public var added: Bool
    /// The messages whose label changed: those that had it, for a removal.
    public var messageIDs: [String]

    public init(undoKey: String, labelID: String, added: Bool, messageIDs: [String]) {
        self.undoKey = undoKey
        self.labelID = labelID
        self.added = added
        self.messageIDs = messageIDs
    }
}

/// A label edit you made, or undid.
public enum UserLabelChange: Sendable, Hashable {
    case applied(LabelEdit)
    case undone(LabelEdit)
}

/// What a label edit meant for the rules that add that label, for the toast after it.
public struct LabelEditNote: Sendable, Hashable {
    /// For a removal: the names of the rules that had added the label to these conversations. They
    /// do not add it there again.
    public var stoppedRules: [String] = []
    /// The names of the rules that learned an example from the edit: ✖ for a removal, ✔ for an addition.
    public var taughtRules: [String] = []

    public init(stoppedRules: [String] = [], taughtRules: [String] = []) {
        self.stoppedRules = stoppedRules
        self.taughtRules = taughtRules
    }
}

/// What rules learn from your label edits, and why a conversation carries its labels.
extension RuleEngine {
    /// Records your edit of a label that a rule adds.
    ///
    /// - Removing it marks the messages that had it (`present = 0`): no rule adds it there again and
    ///   the rules' ownership ends. A new reply is still judged. A rule that had added it and whose
    ///   edits teach (the default) also gets a ✖ example: the latest received message of the
    ///   conversation it labeled.
    /// - Adding it marks the conversation's received messages, never your own replies (`present = 1`):
    ///   undo and re-checks never take it off. Rules whose edits teach get a ✔ example: the latest
    ///   received message they labeled, else the latest received one.
    /// - Undoing the edit deletes the marks and examples it made.
    ///
    /// Only rules with an ASK learn from examples. Edits of labels no rule adds are not recorded.
    /// Returns which rules stopped adding the label and which learned from the edit.
    @discardableResult
    public func noteUserChange(_ change: UserLabelChange) async throws -> LabelEditNote {
        var note = LabelEditNote()
        switch change {
        case .undone(let edit):
            try await writing { try await store.deleteMarksAndExamples(undoKey: edit.undoKey) }
        case .applied(let edit):
            try await loadIfNeeded()
            let targeting = records.map(\.rule).filter { $0.labelTargets.contains { $0.id == edit.labelID } }
            guard !targeting.isEmpty, !edit.messageIDs.isEmpty else { return note }
            let threadIDs = Set(try await store.messageFacts(edit.messageIDs).map(\.threadID)).sorted()
            let me = store.selfAddresses
            let received = try await store.messageLabels(inThreads: threadIDs)
                .filter { !$0.isLocal && !me.contains($0.fromEmail.lowercased()) && $0.labels.isDisjoint(with: [SystemLabel.sent, SystemLabel.draft]) }
                .sorted { $0.date > $1.date }
            // Read before the marks: a removal ends the rules' ownership.
            let owners = try await store.ruleOwners(ofLabel: edit.labelID, inThreads: threadIDs)
            let marked = edit.added ? received.map(\.messageID) : edit.messageIDs
            try await writing {
                try await store.setLabelMarks(messageIDs: marked, labelID: edit.labelID, present: edit.added, undoKey: edit.undoKey)
            }

            if !edit.added { note.stoppedRules = targeting.filter { owners[$0.id] != nil }.map(\.name) }
            var taught = 0
            for rule in targeting where rule.editsTeach && rule.asksClaude {
                let labeled = Set(owners[rule.id] ?? [])
                var learned = false
                for threadID in threadIDs {
                    let messages = received.filter { $0.threadID == threadID }
                    let owned = messages.first { labeled.contains($0.messageID) }
                    // A removal teaches only the rules that had added the label here.
                    guard let example = owned ?? (edit.added ? messages.first : nil) else { continue }
                    try await writing {
                        try await store.setExample(ruleID: rule.id, messageID: example.messageID, matches: edit.added, origin: .edit, undoKey: edit.undoKey)
                    }
                    taught += 1
                    learned = true
                }
                if learned { note.taughtRules.append(rule.name) }
            }
            Self.log.info("Label edit noted: \(marked.count) mark(s), \(taught) example(s)")
        }
        refreshStatus()
        return note
    }

    /// Your verdict on one message for one rule, from "why these labels?" (`x` it's wrong, `a` it
    /// should match): a ✖ or ✔ example under the label edit's undo key, so undoing the edit deletes
    /// it, also when the edit changed no label. Returns the rule's name when it learns from examples
    /// (it has an ASK), else nil.
    @discardableResult
    public func teach(ruleID: String, messageID: String, matches: Bool, undoKey: String) async throws -> String? {
        try await loadIfNeeded()
        try await writing {
            _ = try await store.setExample(ruleID: ruleID, messageID: messageID, matches: matches, origin: .explain, undoKey: undoKey)
        }
        guard let rule = records.first(where: { $0.id == ruleID })?.rule, rule.asksClaude else { return nil }
        return rule.name
    }

    /// Why a conversation's messages carry their labels: the rules that own each, how they decided
    /// and Claude's reason, with the rules' current names; and the rules that decided no.
    public func explain(threadID: String) async throws -> ThreadExplanation {
        try await store.explain(threadID: threadID)
    }
}
