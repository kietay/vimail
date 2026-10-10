import MailCore
import MailStore
import Observation

/// The people manager (`gp`): the lists of people on the left, in order (the first is the quick
/// list of `i`), and the people on the highlighted list on the right.
@MainActor
@Observable
final class PeopleManagerModel {
    enum Focus { case lists, members }

    /// What the text field at the bottom is for.
    enum Input: Equatable {
        case newList
        case rename(listID: String)
        /// Stays open after each entry, for the next one.
        case add(listID: String)
    }

    /// A question in the manager, answered with a key.
    enum Prompt: Equatable {
        /// `dd` on a list. `rules`: the rules that name it, which then match no mail.
        case deleteList(id: String, name: String, rules: [String])
    }

    private(set) var members: [ContactListMember] = []
    /// The names of the rules that name each list, by `ContactList.key`.
    private(set) var usage: [String: [String]] = [:]
    private(set) var loaded = false
    var focus = Focus.lists
    private(set) var listHighlighted = 0
    private(set) var memberHighlighted = 0
    private(set) var input: Input?
    var inputText = "" {
        didSet { if inputText != oldValue { textChanged() } }
    }
    /// People you have written with who match what is typed, while adding.
    private(set) var suggestions: [EmailAddress] = []
    /// -1: what is typed, not a suggestion.
    private(set) var suggestionHighlighted = -1
    /// Why the last entry was not taken.
    private(set) var notice: String?
    var prompt: Prompt?
    /// The first `d` of `dd`.
    var pendingDelete = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    /// The list to highlight once the app has it.
    @ObservationIgnored private var wantedListID: String?

    init(app: AppModel) {
        self.app = app
        services = app.services
    }

    var lists: [ContactList] { app?.contactLists ?? [] }

    var highlightedList: ContactList? {
        lists.indices.contains(listHighlighted) ? lists[listHighlighted] : nil
    }

    var highlightedMember: ContactListMember? {
        members.indices.contains(memberHighlighted) ? members[memberHighlighted] : nil
    }

    func open() {
        focus = .lists
        input = nil
        inputText = ""
        prompt = nil
        notice = nil
        pendingDelete = false
    }

    // MARK: - Loading

    /// Reads the highlighted list's people and which rules name the lists.
    func reload() {
        if let id = wantedListID, let index = lists.firstIndex(where: { $0.id == id }) {
            listHighlighted = index
            wantedListID = nil
        }
        listHighlighted = min(listHighlighted, max(0, lists.count - 1))
        let list = highlightedList
        let store = services.store
        loadTask?.cancel()
        loadTask = Task {
            let found = list == nil ? [] : (try? await store.contactListMembers(listID: list!.id))
            let rules = (try? await store.rules()) ?? []
            guard !Task.isCancelled else { return }
            if let found {
                let current = highlightedMember?.address
                members = found
                memberHighlighted = current.flatMap { address in found.firstIndex { $0.address == address } } ?? min(memberHighlighted, max(0, found.count - 1))
            }
            var usage: [String: [String]] = [:]
            for record in rules {
                for key in RuleFilter.lists(in: record.rule.when).sorted() { usage[key, default: []].append(record.rule.name) }
            }
            self.usage = usage
            loaded = true
        }
    }

    func move(_ delta: Int) {
        switch focus {
        case .lists:
            let target = min(max(listHighlighted + delta, 0), max(0, lists.count - 1))
            guard target != listHighlighted else { return }
            listHighlighted = target
            memberHighlighted = 0
            members = []
            reload()
        case .members:
            memberHighlighted = min(max(memberHighlighted + delta, 0), max(0, members.count - 1))
        }
    }

    func highlight(list index: Int) {
        focus = .lists
        guard index != listHighlighted else { return }
        listHighlighted = index
        memberHighlighted = 0
        members = []
        reload()
    }

    func highlight(member index: Int) {
        focus = .members
        memberHighlighted = index
    }

    // MARK: - Typing

    func beginInput(_ kind: Input, text: String = "") {
        input = kind
        inputText = text
        notice = nil
        suggestions = []
        suggestionHighlighted = -1
        app?.focusTarget = .peopleInput
    }

    func beginRename() {
        guard let list = highlightedList else { return }
        beginInput(.rename(listID: list.id), text: list.name)
    }

    /// `a`: add to the highlighted list; with no list yet, make one first.
    func beginAdd() {
        guard let list = highlightedList else {
            beginInput(.newList)
            return
        }
        focus = .members
        beginInput(.add(listID: list.id))
    }

    func endInput() {
        input = nil
        inputText = ""
        suggestions = []
        suggestionHighlighted = -1
        notice = nil
        suggestTask?.cancel()
        app?.focusTarget = nil
        app?.blurTextInput()
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        // From what is typed (-1) down through the suggestions and back.
        let count = suggestions.count + 1
        suggestionHighlighted = (suggestionHighlighted + 1 + delta + count) % count - 1
    }

    private func textChanged() {
        notice = nil
        suggestionHighlighted = -1
        suggestTask?.cancel()
        guard case .add = input else { return }
        let text = inputText
        let store = services.store
        let present = Set(members.map(\.address))
        suggestTask = Task {
            let found = (try? await store.contacts(matching: text, limit: 8)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = Array(found.filter { !present.contains($0.normalized) }.prefix(5))
        }
    }

    func commitInput() {
        guard let input else { return }
        let text = inputText.trimmingCharacters(in: .whitespaces)
        let store = services.store
        switch input {
        case .newList:
            guard !text.isEmpty else { return endInput() }
            Task {
                do {
                    let list = try await store.createContactList(name: text)
                    wantedListID = list.id
                    await app?.reloadContactLists()
                    members = []
                    reload()
                    // Straight on to its people.
                    focus = .members
                    beginInput(.add(listID: list.id))
                } catch {
                    notice = error.localizedDescription
                }
            }
        case .rename(let listID):
            guard !text.isEmpty else { return endInput() }
            Task {
                do {
                    let rules = try await store.renameContactList(id: listID, to: text)
                    endInput()
                    if rules > 0, let name = ContactList.cleanName(text) {
                        app?.showToast("\(rules == 1 ? "1 rule names" : "\(rules) rules name") it as \(ContactList.term(name)) now.")
                    }
                } catch {
                    notice = error.localizedDescription
                }
            }
        case .add(let listID):
            guard !text.isEmpty || suggestionHighlighted >= 0 else { return endInput() }
            guard let entries = entries(from: text) else { return }
            Task {
                do {
                    let edit = try await store.addToContactList(listID, entries)
                    if edit.added.isEmpty {
                        notice = entries.count == 1 ? "\(entries[0].displayName) is on the list already." : "They are on the list already."
                    } else {
                        app?.pushUndo(.contacts(edit, runID: nil))
                        notice = nil
                    }
                    inputText = ""
                    suggestions = []
                } catch {
                    notice = error.localizedDescription
                }
            }
        }
    }

    /// What ↵ adds: the highlighted suggestion; else what is typed, when every part of it (split at
    /// commas) is an address or a domain; else the first suggestion. nil, with a notice, otherwise.
    private func entries(from text: String) -> [ContactListMember]? {
        if suggestions.indices.contains(suggestionHighlighted) { return [ContactListMember(suggestions[suggestionHighlighted])] }
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsed = parts.map { ContactListMember.parse($0) }
        if !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) { return parsed.compactMap { $0 } }
        if parts.count <= 1, let first = suggestions.first { return [ContactListMember(first)] }
        let bad = zip(parts, parsed).first { $0.1 == nil }?.0 ?? text
        notice = "“\(bad)” is not an address (ana@studio.co) or a domain (@studio.co)."
        return nil
    }

    // MARK: - Lists

    /// `J` / `K`: the first list is the quick list.
    func reorder(_ delta: Int) {
        guard let list = highlightedList else { return }
        let store = services.store
        wantedListID = list.id
        Task {
            do {
                try await store.moveContactList(id: list.id, by: delta)
            } catch {
                app?.showToast("Could not move the list: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `dd`: asks before deleting a list; removes a person at once (`u` brings them back).
    func deleteHighlighted() {
        switch focus {
        case .lists:
            guard let list = highlightedList else { return }
            prompt = .deleteList(id: list.id, name: list.name, rules: usage[list.key] ?? [])
        case .members:
            guard let list = highlightedList, let member = highlightedMember else { return }
            let store = services.store
            Task {
                do {
                    let edit = try await store.removeFromContactList(list.id, addresses: [member.address])
                    guard !edit.removed.isEmpty else { return }
                    app?.pushUndo(.contacts(edit, runID: nil))
                    app?.showToast(edit.summary, undoable: true)
                } catch {
                    app?.showToast("Could not remove them: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    func delete(_ listID: String) {
        prompt = nil
        let store = services.store
        Task {
            do {
                try await store.deleteContactList(id: listID)
                focus = .lists
            } catch {
                app?.showToast("Could not delete the list: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `s`: all mail from the highlighted list. `↵` on a person: all mail from them.
    func showMail(ofList: Bool) {
        if ofList || focus == .lists {
            guard let list = highlightedList else { return }
            app?.showMail(search: "\(list.term) in:all")
        } else if let member = highlightedMember {
            app?.showMail(search: "from:\(member.address) in:all")
        }
    }
}
