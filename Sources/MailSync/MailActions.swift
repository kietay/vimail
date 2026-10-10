import Foundation
import MailCore
import MailStore

/// Conversation-level actions, with Gmail semantics.
public enum ThreadAction: Hashable, Sendable {
    case archive
    /// Adds INBOX (and removes TRASH/SPAM), for example from Archive or Trash.
    case moveToInbox
    case trash
    case spam
    case notSpam
    case markRead
    case markUnread
    case star
    case unstar
    case addLabel(String)
    case removeLabel(String)
    /// Adds the label and removes INBOX (Gmail "Move to").
    case moveToLabel(String)
    case snooze(until: Date)
    case unsnooze
    /// Returns a snoozed conversation to the inbox as unread.
    case wakeFromSnooze
    /// Permanent. Not undoable.
    case deleteForever

    /// Toast text, for example "Archived 3 conversations".
    public func summary(count: Int, labelName: String? = nil) -> String {
        let noun = count == 1 ? "conversation" : "\(count) conversations"
        let one = count == 1
        switch self {
        case .archive: return one ? "Archived." : "Archived \(noun)."
        case .moveToInbox: return one ? "Moved to Inbox." : "Moved \(noun) to Inbox."
        case .trash: return one ? "Moved to Trash." : "Moved \(noun) to Trash."
        case .spam: return one ? "Marked as spam." : "Marked \(noun) as spam."
        case .notSpam: return one ? "Moved out of Spam." : "Moved \(noun) out of Spam."
        case .markRead: return one ? "Marked as read." : "Marked \(noun) as read."
        case .markUnread: return one ? "Marked as unread." : "Marked \(noun) as unread."
        case .star: return one ? "Starred." : "Starred \(noun)."
        case .unstar: return one ? "Unstarred." : "Unstarred \(noun)."
        case .addLabel: return "Labeled \(one ? "" : "\(noun) ")\(labelName.map { "“\($0)”" } ?? "")."
        case .removeLabel: return "Removed \(labelName.map { "“\($0)”" } ?? "label")\(one ? "" : " from \(noun)")."
        case .moveToLabel: return "Moved \(one ? "" : "\(noun) ")to \(labelName.map { "“\($0)”" } ?? "label")."
        case .snooze(let until): return "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))."
        case .unsnooze: return one ? "Unsnoozed." : "Unsnoozed \(noun)."
        case .wakeFromSnooze: return one ? "Snooze ended." : "\(noun) back from snooze."
        case .deleteForever: return one ? "Deleted forever." : "Deleted \(noun) forever."
        }
    }
}

/// Everything needed to undo an action.
public struct UndoRecord: Sendable {
    public let summary: String
    public let action: ThreadAction
    public let threadIDs: [String]
    let applied: AppliedMutation
    /// Set when the action changed one message only, not its conversation.
    public var messageID: String?

    /// The messages the action added `labelID` to (or removed it from): only those that changed, not
    /// those that already had it (or never had it). Your label edits are reported to rules with them.
    public func messageIDs(changing labelID: String, added: Bool) -> [String] {
        var seen = Set<String>()
        return applied.deltas
            .filter { (added ? $0.delta.add : $0.delta.remove).contains(labelID) }
            .flatMap(\.delta.messageIDs)
            .filter { seen.insert($0).inserted }
    }
}

/// Applies actions optimistically to the local store and queues them for the provider.
/// Every action is one SQLite transaction, so the UI updates instantly, offline or not.
public final class MailActions: Sendable {
    public let store: MailStore
    private let outboxChanged: @Sendable () -> Void

    /// `outboxChanged` is called after an action queues provider work (the sync engine's wake).
    public init(store: MailStore, outboxChanged: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.outboxChanged = outboxChanged
    }

    @discardableResult
    public func perform(_ action: ThreadAction, threads threadIDs: [String], labelName: String? = nil) async throws -> UndoRecord? {
        let threadIDs = Array(NSOrderedSet(array: threadIDs)) as? [String] ?? threadIDs
        guard !threadIDs.isEmpty else { return nil }
        let states = try await store.messageLabels(inThreads: threadIDs)
        let localLabels = Set(try await store.labels().filter { $0.kind == .local }.map(\.id))
        let mutation = Self.plan(action, threadIDs: threadIDs, states: states, localLabels: localLabels)
        guard !mutation.isEmpty else { return nil }
        let applied = try await store.apply(mutation)
        outboxChanged()
        guard applied.isUndoable else { return nil }
        return UndoRecord(summary: action.summary(count: threadIDs.count, labelName: labelName), action: action, threadIDs: threadIDs, applied: applied)
    }

    /// Marks one message read and leaves the rest of its conversation as it is.
    @discardableResult
    public func markRead(message messageID: String, inThread threadID: String) async throws -> UndoRecord? {
        let states = try await store.messageLabels(inThreads: [threadID])
        guard let state = states.first(where: { $0.messageID == messageID }), state.labels.contains(SystemLabel.unread) else { return nil }
        let delta = PlannedDelta(LabelDelta(messageIDs: [messageID], remove: [SystemLabel.unread]), syncs: !state.isLocal)
        let applied = try await store.apply(LocalMutation(deltas: [delta]))
        outboxChanged()
        return UndoRecord(summary: "Marked the message as read.", action: .markRead, threadIDs: [threadID], applied: applied, messageID: messageID)
    }

    public func undo(_ record: UndoRecord) async throws {
        try await store.revert(record.applied)
        outboxChanged()
    }

    /// Finds a label by name (case-insensitive) or creates it.
    public func ensureLabel(named name: String, kind: MailLabel.Kind) async throws -> MailLabel {
        let (label, created) = try await store.ensureLabel(named: name, kind: kind)
        // Only a new Gmail label has something to sync.
        if created && label.kind == .user { outboxChanged() }
        return label
    }

    // MARK: - Planning

    /// Computes the exact per-message label changes for an action.
    static func plan(_ action: ThreadAction, threadIDs: [String], states: [MessageLabelState], localLabels: Set<String>) -> LocalMutation {
        var adds: [String: Set<String>] = [:]
        var removes: [String: Set<String>] = [:]
        var snoozes: [String: Date?] = [:]
        let byThread = Dictionary(grouping: states, by: \.threadID)

        func add(_ label: String, _ state: MessageLabelState) {
            if !state.labels.contains(label) { adds[state.messageID, default: []].insert(label) }
        }
        func remove(_ label: String, _ state: MessageLabelState) {
            if state.labels.contains(label) { removes[state.messageID, default: []].insert(label) }
        }

        for threadID in threadIDs {
            let messages = (byThread[threadID] ?? []).sorted { $0.date < $1.date }
            guard let latest = messages.last else { continue }
            switch action {
            case .archive:
                messages.forEach { remove(SystemLabel.inbox, $0) }
            case .moveToInbox, .notSpam:
                messages.forEach {
                    add(SystemLabel.inbox, $0)
                    remove(SystemLabel.trash, $0)
                    remove(SystemLabel.spam, $0)
                }
                if case .moveToInbox = action { snoozes[threadID] = .some(nil) }
            case .trash:
                messages.forEach {
                    add(SystemLabel.trash, $0)
                    remove(SystemLabel.inbox, $0)
                }
                snoozes[threadID] = .some(nil)
            case .spam:
                messages.forEach {
                    add(SystemLabel.spam, $0)
                    remove(SystemLabel.inbox, $0)
                }
            case .markRead:
                messages.forEach { remove(SystemLabel.unread, $0) }
            case .markUnread:
                add(SystemLabel.unread, latest)
            case .star:
                if !messages.contains(where: { $0.labels.contains(SystemLabel.starred) }) { add(SystemLabel.starred, latest) }
            case .unstar:
                messages.forEach { remove(SystemLabel.starred, $0) }
            case .addLabel(let id):
                messages.forEach { add(id, $0) }
            case .removeLabel(let id):
                messages.forEach { remove(id, $0) }
            case .moveToLabel(let id):
                messages.forEach {
                    add(id, $0)
                    remove(SystemLabel.inbox, $0)
                }
            case .snooze(let until):
                messages.forEach { remove(SystemLabel.inbox, $0) }
                snoozes[threadID] = .some(until)
            case .unsnooze:
                messages.forEach { add(SystemLabel.inbox, $0) }
                snoozes[threadID] = .some(nil)
            case .wakeFromSnooze:
                messages.forEach { add(SystemLabel.inbox, $0) }
                add(SystemLabel.unread, latest)
                snoozes[threadID] = .some(nil)
            case .deleteForever:
                break
            }
        }

        if case .deleteForever = action {
            return LocalMutation(deleteMessageIDs: states.filter { threadIDs.contains($0.threadID) && !$0.isLocal }.map(\.messageID))
        }

        // Group messages with identical changes into one queued operation each.
        struct Key: Hashable { var add: Set<String>; var remove: Set<String>; var syncs: Bool }
        var groups: [Key: [String]] = [:]
        let localMessages = Set(states.filter(\.isLocal).map(\.messageID))
        for state in states {
            let added = adds[state.messageID] ?? []
            let removed = removes[state.messageID] ?? []
            guard !added.isEmpty || !removed.isEmpty else { continue }
            let syncs = !localMessages.contains(state.messageID)
            let remoteKey = Key(add: added.subtracting(localLabels), remove: removed.subtracting(localLabels), syncs: syncs)
            let localKey = Key(add: added.intersection(localLabels), remove: removed.intersection(localLabels), syncs: false)
            if !remoteKey.add.isEmpty || !remoteKey.remove.isEmpty { groups[remoteKey, default: []].append(state.messageID) }
            if !localKey.add.isEmpty || !localKey.remove.isEmpty { groups[localKey, default: []].append(state.messageID) }
        }
        let deltas = groups
            .sorted { $0.value.first ?? "" < $1.value.first ?? "" }
            .map { PlannedDelta(LabelDelta(messageIDs: $0.value, add: $0.key.add, remove: $0.key.remove), syncs: $0.key.syncs) }
        return LocalMutation(deltas: deltas, snoozes: snoozes)
    }
}
