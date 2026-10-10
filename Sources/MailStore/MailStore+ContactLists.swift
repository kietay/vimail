import Foundation
import MailCore

/// Lists of people. Local-only: `list:` in search and in a rule's WHEN reads them.
extension MailStore {
    // MARK: - Lists

    /// Every list in order, with how many entries it has.
    public func contactLists() async throws -> [ContactList] {
        try await read { db in try Self.contactLists(db) }
    }

    static func contactLists(_ db: SQLiteDatabase) throws -> [ContactList] {
        try db.query(
            """
            SELECT cl.id, cl.name, cl.position, (SELECT COUNT(*) FROM contact_list_members cm WHERE cm.list_id = cl.id)
            FROM contact_lists cl ORDER BY cl.position, cl.created_at
            """
        ) { ContactList(id: $0.string(0), name: $0.string(1), position: $0.int(2), memberCount: $0.int(3)) }
    }

    static func contactList(id: String, _ db: SQLiteDatabase) throws -> ContactList {
        guard let list = try contactLists(db).first(where: { $0.id == id }) else { throw ContactListError.listNotFound }
        return list
    }

    /// Makes a list at the end of the order. Throws `ContactListError` for a name that cannot be
    /// used or is taken (names differ by more than case).
    public func createContactList(name: String) async throws -> ContactList {
        try await write { db, change in
            change.contacts = true
            return try Self.createContactList(name: name, db)
        }
    }

    static func createContactList(name raw: String, _ db: SQLiteDatabase) throws -> ContactList {
        guard let name = ContactList.cleanName(raw) else { throw ContactListError.invalidName }
        let key = ContactList.key(name)
        if let taken = try db.first("SELECT name FROM contact_lists WHERE key = ?", [key], { $0.string(0) }) { throw ContactListError.nameTaken(taken) }
        let position = try db.scalar("SELECT COALESCE(MAX(position), -1) + 1 FROM contact_lists")
        let list = ContactList(name: name, position: position)
        try db.run("INSERT INTO contact_lists(id, name, key, position, created_at) VALUES (?, ?, ?, ?, ?)", [list.id, name, key, position, Date()])
        return list
    }

    /// Renames a list. Rules that name it in WHEN (`list:old`) name the new one from now on, at the
    /// same revision: they decide the same mail. Returns how many rules changed.
    @discardableResult
    public func renameContactList(id: String, to raw: String) async throws -> Int {
        try await write { db, change in
            let list = try Self.contactList(id: id, db)
            guard let name = ContactList.cleanName(raw) else { throw ContactListError.invalidName }
            let key = ContactList.key(name)
            if let taken = try db.first("SELECT name FROM contact_lists WHERE key = ? AND id != ?", [key, id], { $0.string(0) }) {
                throw ContactListError.nameTaken(taken)
            }
            try db.run("UPDATE contact_lists SET name = ?, key = ? WHERE id = ?", [name, key, id])
            change.contacts = true
            guard key != list.key else { return 0 }
            var rewritten = Set<String>()
            try Self.rewriteRules(db) { rule in
                guard let when = RuleFilter.renamingList(in: rule.when, from: list.name, to: name) else { return nil }
                var copy = rule
                copy.when = when
                rewritten.insert(rule.id)
                return copy
            }
            try Self.rewriteViews(db) { view in
                guard let current = view.senderList, ContactList.key(current) == list.key else { return nil }
                var copy = view
                copy.senderList = name
                change.views = true
                return copy
            }
            if !rewritten.isEmpty { change.rules = true }
            return rewritten.count
        }
    }

    /// Deletes a list and its entries. Rules and views that name it then match no mail.
    public func deleteContactList(id: String) async throws {
        try await write { db, change in
            try db.run("DELETE FROM contact_list_members WHERE list_id = ?", [id])
            try db.run("DELETE FROM contact_lists WHERE id = ?", [id])
            try Self.renumberContactLists(try Self.contactLists(db).map(\.id), db)
            change.contacts = true
        }
    }

    /// Moves a list up (`delta` < 0) or down in the order. The first list is the quick list.
    public func moveContactList(id: String, by delta: Int) async throws {
        try await write { db, change in
            var ids = try Self.contactLists(db).map(\.id)
            guard let index = ids.firstIndex(of: id) else { return }
            let target = min(max(index + delta, 0), ids.count - 1)
            guard target != index else { return }
            ids.insert(ids.remove(at: index), at: target)
            try Self.renumberContactLists(ids, db)
            change.contacts = true
        }
    }

    static func renumberContactLists(_ ids: [String], _ db: SQLiteDatabase) throws {
        for (position, id) in ids.enumerated() {
            try db.run("UPDATE contact_lists SET position = ? WHERE id = ?", [position, id])
        }
    }

    // MARK: - Entries

    /// A list's entries: people by name, then domains.
    public func contactListMembers(listID: String) async throws -> [ContactListMember] {
        try await read { db in
            try db.query(
                """
                SELECT address, name, added_at FROM contact_list_members WHERE list_id = ?
                ORDER BY address LIKE '@%', unicode_lower(COALESCE(name, address)), address
                """,
                [listID], Self.contactListMember
            )
        }
    }

    static func contactListMember(_ row: SQLRow) -> ContactListMember {
        ContactListMember(address: row.string(0), name: row.optionalString(1), addedAt: row.date(2))
    }

    static func contactListMembers(listID: String, addresses: [String], _ db: SQLiteDatabase) throws -> [ContactListMember] {
        try db.query(
            "SELECT address, name, added_at FROM contact_list_members WHERE list_id = ? AND address IN (SELECT value FROM json_each(?))",
            [listID, try json(addresses)], contactListMember
        )
    }

    /// Adds entries to a list. Entries already on it keep their date and gain a name they lacked.
    /// The edit lists the ones that were new.
    @discardableResult
    public func addToContactList(_ listID: String, _ members: [ContactListMember]) async throws -> ContactListEdit {
        try await write { db, change in
            let list = try Self.contactList(id: listID, db)
            change.contacts = true
            return ContactListEdit(listID: listID, listName: list.name, added: try Self.add(members, to: listID, db))
        }
    }

    /// Returns the entries that were not on the list before.
    static func add(_ members: [ContactListMember], to listID: String, _ db: SQLiteDatabase) throws -> [ContactListMember] {
        let present = Set(try contactListMembers(listID: listID, addresses: members.map(\.address), db).map(\.address))
        var added: [ContactListMember] = []
        var seen = present
        for member in members where !member.address.isEmpty {
            try db.run(
                """
                INSERT INTO contact_list_members(list_id, address, name, added_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(list_id, address) DO UPDATE SET name = COALESCE(contact_list_members.name, excluded.name)
                """,
                [listID, member.address, member.name, member.addedAt]
            )
            if seen.insert(member.address).inserted { added.append(member) }
        }
        return added
    }

    /// Takes entries off a list. The edit lists the ones that were on it.
    @discardableResult
    public func removeFromContactList(_ listID: String, addresses: [String]) async throws -> ContactListEdit {
        try await write { db, change in
            let list = try Self.contactList(id: listID, db)
            change.contacts = true
            return ContactListEdit(listID: listID, listName: list.name, removed: try Self.remove(addresses, from: listID, db))
        }
    }

    static func remove(_ addresses: [String], from listID: String, _ db: SQLiteDatabase) throws -> [ContactListMember] {
        let removed = try contactListMembers(listID: listID, addresses: addresses, db)
        for member in removed {
            try db.run("DELETE FROM contact_list_members WHERE list_id = ? AND address = ?", [listID, member.address])
        }
        return removed
    }

    /// One key, one transaction: puts `people` on a list, or takes them off when all of them are on
    /// it already.
    /// - Parameter list: the list's ID; nil for the quick list (the first one), which is made with
    ///   the name `defaultName` when there is no list yet.
    public func toggleContactListMembers(list id: String?, defaultName: String, _ people: [ContactListMember]) async throws -> ContactListEdit {
        try await write { db, change in
            var created = false
            let list: ContactList
            if let id {
                list = try Self.contactList(id: id, db)
            } else if let first = try Self.contactLists(db).first {
                list = first
            } else {
                list = try Self.createContactList(name: defaultName, db)
                created = true
            }
            var edit = ContactListEdit(listID: list.id, listName: list.name, createdList: created)
            let addresses = Array(Set(people.map(\.address)))
            let present = try Self.contactListMembers(listID: list.id, addresses: addresses, db)
            if !addresses.isEmpty, present.count == addresses.count {
                edit.removed = try Self.remove(addresses, from: list.id, db)
            } else {
                edit.added = try Self.add(people, to: list.id, db)
            }
            change.contacts = true
            return edit
        }
    }

    /// Takes back an edit: what it added goes, what it removed returns with its date, and a list it
    /// made is deleted when it is empty again.
    public func undoContactListEdit(_ edit: ContactListEdit) async throws {
        try await write { db, change in
            change.contacts = true
            guard try db.first("SELECT 1 FROM contact_lists WHERE id = ?", [edit.listID], { _ in true }) != nil else { return }
            _ = try Self.remove(edit.added.map(\.address), from: edit.listID, db)
            _ = try Self.add(edit.removed, to: edit.listID, db)
            if edit.createdList, try db.scalar("SELECT COUNT(*) FROM contact_list_members WHERE list_id = ?", [edit.listID]) == 0 {
                try db.run("DELETE FROM contact_lists WHERE id = ?", [edit.listID])
            }
        }
    }

    // MARK: - Who is on which list

    /// The lists each address is on, by list ID: with its own entry, or (`includingDomains`) with
    /// its domain's.
    public func contactListMemberships(of addresses: [String], includingDomains: Bool = true) async throws -> [String: Set<String>] {
        try await read { db in
            var result: [String: Set<String>] = [:]
            for address in Set(addresses.map { $0.lowercased() }) {
                let domain = includingDomains ? address.firstIndex(of: "@").map { String(address[$0...]) } ?? address : address
                let lists = try db.query("SELECT list_id FROM contact_list_members WHERE address IN (?, ?)", [address, domain]) { $0.string(0) }
                if !lists.isEmpty { result[address] = Set(lists) }
            }
            return result
        }
    }

    /// The people conversations are from, in the order given and each once: the sender of a
    /// conversation's newest message that is not yours. A conversation with only your own messages
    /// gives the people its newest message went to.
    public func correspondents(ofThreads threadIDs: [String]) async throws -> [EmailAddress] {
        let me = selfAddresses
        return try await read { db in
            var people: [EmailAddress] = []
            var seen = Set<String>()
            for threadID in threadIDs {
                let rows = try db.query(
                    "SELECT from_name, from_email, to_json, cc_json FROM messages WHERE thread_id = ? ORDER BY date DESC", [threadID]
                ) { (EmailAddress(name: $0.optionalString(0), email: $0.string(1)), $0.string(2), $0.string(3)) }
                var found: [EmailAddress] = []
                if let sender = rows.map(\.0).first(where: { !me.contains($0.normalized) }) {
                    found = [sender]
                } else if let newest = rows.first {
                    let recipients = try [newest.1, newest.2].flatMap { try Self.decoder.decode([EmailAddress].self, from: Data($0.utf8)) }
                    found = recipients.filter { !me.contains($0.normalized) }
                }
                for person in found where !person.normalized.isEmpty && seen.insert(person.normalized).inserted { people.append(person) }
            }
            return people
        }
    }
}
