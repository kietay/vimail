import MailCore
import MailStore
import Observation

/// Contacts that match what is typed in an address field (compose's To, Cc and Bcc, the event editor's Guests),
/// looked up as you type. ↑ ↓ move through them, ↵ or tab takes one.
@MainActor
@Observable
final class ContactSuggestions {
    private(set) var items: [EmailAddress] = []
    private(set) var index = 0
    @ObservationIgnored private let store: MailStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: MailStore) {
        self.store = store
    }

    var isEmpty: Bool { items.isEmpty }

    /// Looks up `token` after a short pause. `excluded` (addresses already added) is read when the matches arrive.
    func update(for token: String, excluding excluded: @escaping () -> Set<String>) {
        task?.cancel()
        guard !token.isEmpty, !token.contains("<") else {
            items = []
            return
        }
        let store = store
        task = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let found = try? await store.contacts(matching: token) else { return }
            let existing = excluded()
            items = found.filter { !existing.contains($0.normalized) }
            index = 0
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    /// The highlighted match, or the one at `index` (a click). The list closes.
    func take(at index: Int? = nil) -> EmailAddress? {
        guard !items.isEmpty else { return nil }
        let chosen = items[min(index ?? self.index, items.count - 1)]
        items = []
        return chosen
    }

    /// Esc: the list closes, and a lookup still on its way does not open it again.
    func close() {
        task?.cancel()
        items = []
    }
}
