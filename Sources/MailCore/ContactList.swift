import Foundation

/// A named list of people, such as "VIP" or "Investors". Search and rules test a message's sender
/// against it with `list:name`. Lists are local: nothing about them is sent to the provider.
public struct ContactList: Hashable, Sendable, Identifiable {
    /// "cl_8f2a1c3d".
    public let id: String
    public var name: String
    /// Lists are shown in this order. The first one is the quick list (`i`).
    public var position: Int
    public var memberCount: Int

    public init(id: String = ContactList.makeID(), name: String, position: Int = 0, memberCount: Int = 0) {
        self.id = id
        self.name = name
        self.position = position
        self.memberCount = memberCount
    }

    public static func makeID() -> String { "cl_\(UUID().uuidString.prefix(8).lowercased())" }

    /// What `list:` compares: names match without regard to case.
    public var key: String { Self.key(name) }

    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A name as it is stored: trimmed, inner whitespace as single spaces. nil when it is empty or
    /// has a quote or a colon, which a `list:` term cannot carry.
    public static func cleanName(_ raw: String) -> String? {
        let name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, !name.contains("\""), !name.contains(":") else { return nil }
        return name
    }

    /// The search term for this list: `list:vip`, or `list:"close friends"`.
    public var term: String { Self.term(name) }

    public static func term(_ name: String) -> String {
        let key = key(name)
        return key.contains(" ") ? "list:\"\(key)\"" : "list:\(key)"
    }
}

/// One entry of a list: a person's address, or a whole domain.
public struct ContactListMember: Hashable, Sendable, Identifiable {
    /// "a@b.com", or "@b.com" for everyone at b.com. Lowercased.
    public var address: String
    public var name: String?
    public var addedAt: Date

    public init(address: String, name: String? = nil, addedAt: Date = Date()) {
        self.address = address
        self.name = name
        self.addedAt = addedAt
    }

    public var id: String { address }
    public var isDomain: Bool { address.hasPrefix("@") }
    public var displayName: String { name ?? address }

    public init(_ person: EmailAddress, addedAt: Date = Date()) {
        self.init(address: person.normalized, name: person.name, addedAt: addedAt)
    }

    /// An entry from what you type: `Name <a@b.com>`, `a@b.com`, `@b.com` or `b.com`. nil when it
    /// is none of these.
    public static func parse(_ text: String) -> ContactListMember? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("<"), !trimmed.contains(where: \.isWhitespace) {
            let domain = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
            if !domain.contains("@") {
                let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
                guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
                return ContactListMember(address: "@\(domain.lowercased())")
            }
        }
        guard let person = EmailAddress.parse(trimmed), person.isValid else { return nil }
        return ContactListMember(person)
    }
}

/// What a change to a list did, so it can be undone.
public struct ContactListEdit: Hashable, Sendable {
    public var listID: String
    public var listName: String
    /// The change made the list: undoing it deletes the list when nothing else was added since.
    public var createdList = false
    public var added: [ContactListMember] = []
    public var removed: [ContactListMember] = []

    public init(listID: String, listName: String, createdList: Bool = false, added: [ContactListMember] = [], removed: [ContactListMember] = []) {
        self.listID = listID
        self.listName = listName
        self.createdList = createdList
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && !createdList }

    /// "Added Alex Morgan to VIP." / "Removed 3 people from VIP."
    public var summary: String {
        func people(_ members: [ContactListMember]) -> String {
            members.count == 1 ? members[0].displayName : "\(members.count) people"
        }
        if !added.isEmpty { return "Added \(people(added)) to \(listName)." }
        if !removed.isEmpty { return "Removed \(people(removed)) from \(listName)." }
        return createdList ? "Made the list \(listName)." : "\(listName) did not change."
    }
}

public enum ContactListError: Error, Hashable, Sendable, LocalizedError {
    case invalidName
    case nameTaken(String)
    case listNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidName: "A list needs a name without quotes or colons."
        case .nameTaken(let name): "There is already a list named \(name)."
        case .listNotFound: "That list is gone."
        }
    }
}
