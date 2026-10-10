import Foundation
import Testing
@testable import MailCore
@testable import MailStore

@Suite("Lists of people in the store")
struct ContactListStoreTests {
    func threads(_ store: MailStore, _ search: String) async throws -> Set<String> {
        Set(try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse(search))).map(\.id))
    }

    @Test func listsKeepTheirOrderAndUniqueNames() async throws {
        let store = try await seededStore()
        let vip = try await store.createContactList(name: " VIP ")
        let vendors = try await store.createContactList(name: "Vendors")
        #expect(try await store.contactLists().map(\.name) == ["VIP", "Vendors"])
        await #expect(throws: ContactListError.nameTaken("VIP")) { try await store.createContactList(name: "vip") }
        await #expect(throws: ContactListError.invalidName) { try await store.createContactList(name: "a:b") }
        try await store.moveContactList(id: vendors.id, by: -1)
        #expect(try await store.contactLists().map(\.name) == ["Vendors", "VIP"])
        try await store.deleteContactList(id: vendors.id)
        #expect(try await store.contactLists().map { [$0.id, "\($0.position)"] } == [[vip.id, "0"]])
    }

    @Test func searchFindsMailFromPeopleOnAList() async throws {
        let store = try await seededStore()
        let vip = try await store.createContactList(name: "VIP")
        #expect(try await threads(store, "list:vip").isEmpty)
        let edit = try await store.addToContactList(vip.id, [ContactListMember(nina)])
        #expect(edit.added.map(\.address) == ["nina@parkhouse.me"] && edit.summary == "Added Nina Park to VIP.")
        #expect(try await threads(store, "list:VIP") == ["t2"])
        #expect(try await threads(store, "-list:vip") == ["t1", "t3"])
        // A whole domain.
        try await store.addToContactList(vip.id, [ContactListMember(address: "@studionorth.co")])
        #expect(try await threads(store, "list:vip") == ["t1", "t2", "t3"])
        #expect(try await store.contactLists().first?.memberCount == 2)
        #expect(try await store.contactListMembers(listID: vip.id).map(\.address) == ["nina@parkhouse.me", "@studionorth.co"])
        // A list that does not exist matches nothing, with or without the minus.
        #expect(try await threads(store, "list:nobody").isEmpty)
        #expect(try await threads(store, "-list:nobody").isEmpty)
    }

    @Test func savedViewsCanShowAList() async throws {
        let store = try await seededStore()
        let vip = try await store.createContactList(name: "VIP")
        try await store.addToContactList(vip.id, [ContactListMember(nina)])
        let view = SavedView(name: "VIPs", senderList: "vip")
        #expect(try await store.threads(view.query).map(\.id) == ["t2"])
        // Views saved before lists existed still decode.
        let old = try JSONDecoder().decode(SavedView.self, from: Data(#"{"id":"v","name":"Old","pinned":true,"status":"any","starredOnly":false,"sender":"","text":"","position":0}"#.utf8))
        #expect(old.senderList == nil)
    }

    @Test func messageQueriesAgreeWithConversationSearch() async throws {
        let store = try await messageQueryStore()
        let team = try await store.createContactList(name: "team")
        try await store.addToContactList(team.id, [ContactListMember(alex), ContactListMember(address: "@thebrowser.com")])
        for text in ["list:team", "-list:team", "list:none", "-list:none"] {
            try await MessageQueryTests().expectParity(store, SearchQuery.parse(text), negated: text.hasPrefix("-"))
        }
        #expect(Set(try messageMatches(store, .parse("list:team")).map(\.id)) == ["m1", "m4", "m5"])
        #expect(try messageMatches(store, .parse("-list:none")).isEmpty)
    }

    @Test func oneKeyTogglesAndUndoes() async throws {
        let store = try await seededStore()
        let people = [ContactListMember(nina), ContactListMember(alex)]
        // No list yet: the quick list is made.
        let first = try await store.toggleContactListMembers(list: nil, defaultName: "VIP", [people[0]])
        #expect(first.createdList && first.listName == "VIP" && first.added.count == 1)
        // One of two is on it: the other joins.
        let second = try await store.toggleContactListMembers(list: nil, defaultName: "VIP", people)
        #expect(!second.createdList && second.added.map(\.address) == ["alex@studionorth.co"] && second.removed.isEmpty)
        // Both are on it: both leave.
        let third = try await store.toggleContactListMembers(list: first.listID, defaultName: "VIP", people)
        #expect(third.added.isEmpty && third.removed.count == 2)
        try await store.undoContactListEdit(third)
        #expect(try await store.contactListMembers(listID: first.listID).count == 2)
        try await store.undoContactListEdit(second)
        try await store.undoContactListEdit(first)
        #expect(try await store.contactLists().isEmpty)
    }

    @Test func membershipsCountDomains() async throws {
        let store = try await seededStore()
        let vip = try await store.createContactList(name: "VIP")
        let work = try await store.createContactList(name: "Work")
        try await store.addToContactList(vip.id, [ContactListMember(alex)])
        try await store.addToContactList(work.id, [ContactListMember(address: "@studionorth.co")])
        let memberships = try await store.contactListMemberships(of: ["Alex@studionorth.co", "nina@parkhouse.me"])
        #expect(memberships == ["alex@studionorth.co": [vip.id, work.id]])
    }

    @Test func correspondentsAreTheOtherPeople() async throws {
        let store = try await seededStore()
        try await store.upsertMessages([message("m9", thread: "t9", from: me, to: [nina, me], subject: "Hi", labels: ["SENT"], minutesAgo: 1)])
        // t1: Alex wrote, then you answered. t9: only you wrote, to Nina.
        #expect(try await store.correspondents(ofThreads: ["t1", "t9", "t2", "missing"]) == [alex, nina])
    }

    @Test func renamingAListRewritesRulesAndViews() async throws {
        let store = try await seededStore()
        let vip = try await store.createContactList(name: "VIP")
        try await store.addToContactList(vip.id, [ContactListMember(nina)])
        let label = try await store.resolveLabel(name: "important")
        let record = try await store.createRule(Rule(key: "", name: "VIPs", when: "list:vip is:list", then: [.addLabel(LabelRef(id: label.id, lastKnownName: label.name))]))
        try await store.saveView(SavedView(id: "v1", name: "VIPs", senderList: "VIP"))
        #expect(try await store.renameContactList(id: vip.id, to: "Inner Circle") == 1)
        let rule = try #require(try await store.rules().first)
        #expect(rule.rule.when == "list:\"inner circle\" is:list" && rule.rule.revision == record.rule.revision)
        #expect(try await store.savedViews().first?.senderList == "Inner Circle")
        #expect(try await threads(store, "list:\"inner circle\"") == ["t2"])
        // Changing only the case keeps rules as they are.
        #expect(try await store.renameContactList(id: vip.id, to: "inner circle") == 0)
    }
}
