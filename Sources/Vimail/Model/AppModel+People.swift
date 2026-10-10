import MailCore
import MailRules
import MailStore

/// Lists of people: `i` puts the sender on the quick list, `P` ticks lists, `gp` manages them.
/// Search, views and rules read them with `list:name`.
extension AppModel {
    /// The quick list `i` makes when there is no list yet.
    static let defaultListName = "VIP"

    static func peopleText(_ people: [EmailAddress]) -> String {
        people.count == 1 ? people[0].displayName : "\(people.count) people"
    }

    func reloadContactLists() async {
        contactLists = (try? await services.store.contactLists()) ?? contactLists
    }

    /// Lists or the people on them changed in the store.
    func contactListsChanged() async {
        await reloadContactLists()
        peopleManager?.reload()
        if overlay == .picker(.people) { await reloadPickerMemberships() }
    }

    private func peopleTargets(_ ids: [String]?) -> [String] {
        // The calendar view has no conversation under the cursor.
        guard destination != .calendar else { return [] }
        return (ids ?? actionTargets).filter { !$0.hasPrefix("draft:") }
    }

    // MARK: - i: the quick list

    /// i: puts the senders of the selected conversations on the quick list (the first list), or
    /// takes them off when all of them are on it. No picker; `u` undoes it.
    func toggleQuickList(on ids: [String]? = nil) {
        let targets = peopleTargets(ids)
        guard !targets.isEmpty else {
            showToast("Select a conversation first.")
            return
        }
        let services = services
        Task {
            guard let people = await correspondents(of: targets, in: services) else { return }
            await toggle(people, list: nil, threads: targets, in: services)
        }
    }

    private func correspondents(of threads: [String], in services: AppServices) async -> [EmailAddress]? {
        do {
            let people = try await services.store.correspondents(ofThreads: threads)
            if people.isEmpty { showToast("There is no sender to put on a list.") }
            return people.isEmpty ? nil : people
        } catch {
            showToast("Could not read the senders: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    /// Puts people on a list, or takes them off when all of them are on it. The rules that name
    /// the list then look at these conversations, so their labels show at once.
    /// - Parameter id: the list; nil for the quick list.
    func toggle(_ people: [EmailAddress], list id: String?, threads: [String], in services: AppServices) async {
        do {
            let edit = try await services.store.toggleContactListMembers(list: id, defaultName: Self.defaultListName, people.map { ContactListMember($0) })
            guard services === self.services else { return }
            let run = await runListRules(edit, threads: threads, in: services)
            pushUndo(.contacts(edit, runID: run.runID))
            showToast(edit.summary, undoable: true, detail: run.note)
        } catch {
            showToast("Could not change the list: \(error.localizedDescription)", isError: true)
        }
    }

    /// After people joined a list: the enabled rules that name it run on their conversations. A
    /// run that would cost more than `=` spends without asking does not start.
    private func runListRules(_ edit: ContactListEdit, threads: [String], in services: AppServices) async -> (runID: Int64?, note: String?) {
        guard !edit.added.isEmpty, !threads.isEmpty, !settings.ai.pauseAll else { return (nil, nil) }
        do {
            let key = ContactList.key(edit.listName)
            let rules = try await services.store.rules().filter { $0.rule.enabled && $0.state == .ok && RuleFilter.lists(in: $0.rule.when).contains(key) }
            guard !rules.isEmpty else { return (nil, nil) }
            let messages = try await services.store.messageIDs(inThreads: threads)
            let run = try await services.rules.runRules(on: messages, only: Set(rules.map(\.id)))
            let name = rules.count == 1 ? "The rule \(rules[0].rule.name)" : "\(rules.count) rules"
            guard run.runID != nil else {
                return (nil, "Press = to run rules on this mail: Claude would cost about \(Formatting.dollars(run.estimate.micros)).")
            }
            return (run.runID, "\(name) ran on this mail.")
        } catch {
            Self.log.error("Could not run the rules of list \(edit.listID): \(String(describing: type(of: error)))")
            return (nil, nil)
        }
    }

    func undoContacts(_ edit: ContactListEdit, runID: Int64?) {
        let services = services
        Task {
            do {
                try await services.store.undoContactListEdit(edit)
                if let runID { _ = try? await services.rules.undo(.run(runID)) }
                showToast("Undone: \(edit.summary)")
            } catch {
                showToast("Could not undo: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - P: the list picker

    /// P: the lists, ticked where the senders of the selected conversations are on them.
    func openPeoplePicker(on ids: [String]? = nil) {
        let targets = peopleTargets(ids)
        guard !targets.isEmpty else {
            showToast("Select a conversation first.")
            return
        }
        let services = services
        Task {
            guard let people = await correspondents(of: targets, in: services), services === self.services else { return }
            pickerPeople = people
            await reloadPickerMemberships()
            pickerTargets = targets
            overlay = .picker(.people)
        }
    }

    func reloadPickerMemberships() async {
        let addresses = pickerPeople.map(\.normalized)
        pickerMemberships = (try? await services.store.contactListMemberships(of: addresses, includingDomains: false)) ?? pickerMemberships
    }

    func peoplePickerItems(query: String, matches: (String) -> Bool) -> [PickerItem] {
        let people = pickerPeople
        let targets = pickerTargets
        var items: [PickerItem] = contactLists.enumerated().filter { matches($0.element.name) }.map { index, list in
            let on = people.filter { pickerMemberships[$0.normalized]?.contains(list.id) ?? false }.count
            let state: Bool? = on == 0 ? false : (on == people.count ? true : nil)
            let count = list.memberCount == 1 ? "1 entry" : "\(list.memberCount) entries"
            return PickerItem(id: list.id, title: list.name, subtitle: index == 0 ? "quick list (i) · \(count)" : count, checked: .some(state)) { keepOpen in
                if !keepOpen { self.overlay = nil }
                let services = self.services
                Task { await self.toggle(people, list: list.id, threads: targets, in: services) }
            }
        }
        if let name = ContactList.cleanName(query), !contactLists.contains(where: { $0.key == ContactList.key(name) }) {
            items.append(PickerItem(id: "create", title: "Create list “\(name)” with \(Self.peopleText(people))", icon: .plus) { _ in
                self.overlay = nil
                self.createList(named: name, with: people)
            })
        }
        return items
    }

    /// A new list with these people on it. `u` takes them off and deletes the list.
    func createList(named name: String, with people: [EmailAddress]) {
        let services = services
        Task {
            do {
                let list = try await services.store.createContactList(name: name)
                var edit = try await services.store.addToContactList(list.id, people.map { ContactListMember($0) })
                edit.createdList = true
                pushUndo(.contacts(edit, runID: nil))
                showToast(edit.summary, undoable: true, detail: "Rules and search find them with \(list.term).")
            } catch {
                showToast("Could not make the list: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - gp: the manager

    func managePeople() {
        let manager = peopleManager ?? PeopleManagerModel(app: self)
        manager.open()
        peopleManager = manager
        overlay = .people
        manager.reload()
    }

    /// Closes what is open and searches the mail list, as if typed after `/`.
    func showMail(search: String) {
        overlay = nil
        if destination == .calendar { navigate(to: .mailbox(.inbox)) }
        focus = .list
        isSearchOpen = true
        searchText = search
    }
}
