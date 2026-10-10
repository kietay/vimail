import Foundation
import Testing
@testable import MailCore

@Suite("Lists of people")
struct ContactListTests {
    @Test func searchParsesListTerms() {
        let query = SearchQuery.parse("list:VIP -list:\"cold outreach\" from:ana")
        #expect(query.lists == ["VIP"])
        #expect(query.excludedLists == ["cold outreach"])
        #expect(query.from == ["ana"])
        let narrowed = ThreadQuery(scope: .anywhere).narrowed(by: query)
        #expect(narrowed.senderLists == ["VIP"] && narrowed.excludedSenderLists == ["cold outreach"])
    }

    @Test func rulesAcceptListTerms() throws {
        let filter = try RuleFilter.parse("list:vip -list:vendors subject:invoice")
        #expect(filter.query.lists == ["vip"] && filter.query.excludedLists == ["vendors"])
        #expect(throws: RuleFilter.Problem.self) { try RuleFilter.parse("list:") }
        #expect(RuleFilter.lists(in: "list:VIP -list:Vendors from:x") == ["vip", "vendors"])
    }

    @Test func renamingAListRewritesItsTermsOnly() {
        #expect(RuleFilter.renamingList(in: "list:vip  subject:\"board deck\" \"exact phrase\" -list:VIP label:vip", from: "VIP", to: "Inner Circle")
            == "list:\"inner circle\" subject:\"board deck\" \"exact phrase\" -list:\"inner circle\" label:vip")
        #expect(RuleFilter.renamingList(in: "list:\"close friends\" from:a", from: "Close Friends", to: "friends") == "list:friends from:a")
        #expect(RuleFilter.renamingList(in: "list:vendors from:vip", from: "vip", to: "x") == nil)
    }

    @Test func namesAndTerms() {
        #expect(ContactList.cleanName("  Close   Friends ") == "Close Friends")
        #expect(ContactList.cleanName("  ") == nil)
        #expect(ContactList.cleanName("a:b") == nil && ContactList.cleanName("a\"b") == nil)
        #expect(ContactList(name: "VIP").term == "list:vip")
        #expect(ContactList(name: "Close Friends").term == "list:\"close friends\"")
    }

    @Test func entriesFromTypedText() {
        let ana = ContactListMember.parse("Ana Ruiz <Ana@Studio.co>")
        #expect(ana?.address == "ana@studio.co" && ana?.name == "Ana Ruiz" && ana?.isDomain == false)
        #expect(ContactListMember.parse(" ana@studio.co ")?.address == "ana@studio.co")
        #expect(ContactListMember.parse("@Studio.co")?.address == "@studio.co")
        #expect(ContactListMember.parse("studio.co")?.isDomain == true)
        for bad in ["", "ana", "@studio", "ana@", "two words", "a..b"] {
            #expect(ContactListMember.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func editSummaries() {
        let ana = ContactListMember(address: "ana@studio.co", name: "Ana Ruiz")
        let domain = ContactListMember(address: "@studio.co")
        #expect(ContactListEdit(listID: "l", listName: "VIP", added: [ana]).summary == "Added Ana Ruiz to VIP.")
        #expect(ContactListEdit(listID: "l", listName: "VIP", removed: [ana, domain]).summary == "Removed 2 people from VIP.")
        #expect(ContactListEdit(listID: "l", listName: "VIP", added: [domain]).summary == "Added @studio.co to VIP.")
    }
}
