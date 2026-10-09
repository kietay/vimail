import Foundation
import Testing
@testable import MailCore
@testable import MailStore

/// The seeded store plus a newsletter, and a message with Alex in Cc.
func messageQueryStore() async throws -> MailStore {
    let store = try await seededStore()
    var newsletter = message("m5", thread: "t5", from: EmailAddress(name: "The Browser", email: "hello@thebrowser.com"), subject: "Five ideas", body: "Reading list", labels: ["INBOX"], minutesAgo: 2)
    newsletter.listUnsubscribe = "<mailto:unsub@thebrowser.com>"
    var copied = message("m6", thread: "t2", from: nina, subject: "Re: Coffee on Thursday?", body: "Bringing Alex along", labels: ["INBOX"], minutesAgo: 1)
    copied.cc = [alex]
    try await store.upsertMessages([newsletter, copied])
    return store
}

/// Messages passing `search` one at a time (any mailbox), with their conversations.
func messageMatches(_ store: MailStore, _ search: SearchQuery) throws -> [(id: String, thread: String)] {
    try store.readNow { db in
        let (sql, args) = try MailStore.messageQuerySQL(MailStore.MessageQuery(search: search), me: [], selecting: "m.id, m.thread_id", ordered: true)
        return try db.query(sql, args) { (id: $0.string(0), thread: $0.string(1)) }
    }
}

@Suite("Message-level rule queries")
struct MessageQueryTests {
    /// For a positive operator, a conversation matches when one of its messages does.
    /// For a negation, when all of them do (one excluded message drops the conversation).
    @Test(arguments: [
        "budget", "\"budget spreadsheet\"", "valencia", "from:nina", "from:alex", "from:sam", "from:browser",
        "to:alex", "to:sam", "to:studionorth", "subject:coffee", "subject:quarterly", "label:work",
        "has:attachment", "is:list", "-budget", "-from:alex", "-from:nina", "-label:work",
    ])
    func singleOperatorsAgreeWithConversationSearch(_ text: String) async throws {
        let store = try await messageQueryStore()
        let search = SearchQuery.parse(text)
        try await expectParity(store, search, negated: text.hasPrefix("-"))
    }

    @Test func afterAgreesWithConversationSearch() async throws {
        let store = try await messageQueryStore()
        var search = SearchQuery()
        search.after = Date().addingTimeInterval(-25 * 60)
        try await expectParity(store, search, negated: false)
    }

    func expectParity(_ store: MailStore, _ search: SearchQuery, negated: Bool) async throws {
        let matches = try messageMatches(store, search)
        let conversations: Set<String>
        if negated {
            let all = try store.readNow { db in try db.query("SELECT id, thread_id FROM messages") { ($0.string(0), $0.string(1)) } }
            let matched = Set(matches.map(\.id))
            conversations = Set(all.map(\.1)).filter { thread in all.filter { $0.1 == thread }.allSatisfy { matched.contains($0.0) } }
        } else {
            conversations = Set(matches.map(\.thread))
        }
        let threads = try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: search))
        #expect(conversations == Set(threads.map(\.id)))
    }

    @Test func eachOperatorTestsTheMessageItself() async throws {
        let store = try await messageQueryStore()
        func ids(_ text: String) throws -> Set<String> { Set(try messageMatches(store, .parse(text)).map(\.id)) }

        // Alex wrote m1 and Sam wrote "Looks good": no single message has both.
        #expect(try ids("from:alex looks").isEmpty)
        #expect(try ids("from:sam budget") == ["m2"])
        #expect(try ids("from:alex budget") == ["m1"])
        // A negation drops only the matching message, not its conversation.
        #expect(try ids("-from:sam") == ["m1", "m3", "m4", "m5", "m6"])
        #expect(try ids("subject:coffee -from:nina").isEmpty)
        #expect(try ids("subject:re: coffee") == ["m6"])
        #expect(try ids("to:alex") == ["m2", "m6"])
        #expect(try ids("to:alex -from:sam") == ["m6"])
        #expect(try ids("label:work has:attachment") == ["m4"])
        #expect(try ids("is:list -from:browser").isEmpty)
        // Addresses are matched by value, not as raw JSON: "email" and "name" are not in any address.
        #expect(try ids("to:email").isEmpty)
        #expect(try ids("to:name").isEmpty)
    }

    @Test func caseIsIgnoredBeyondASCII() async throws {
        let store = try await messageQueryStore()
        try await store.upsertLabel(MailLabel(id: "Label_9", name: "Ärzte", kind: .user))
        try await store.upsertMessages([
            message("u1", thread: "u1", from: EmailAddress(name: "Émile Zola", email: "emile@zola.fr"), to: [EmailAddress(name: "Øystein", email: "o@example.no")],
                    subject: "Überweisung erhalten", labels: ["INBOX", "Label_9"], minutesAgo: 4),
        ])
        for text in ["from:Émile", "from:émile", "subject:Überweisung", "subject:ÜBERWEISUNG", "to:øystein", "label:Ärzte", "label:ÄRZTE"] {
            #expect(try messageMatches(store, .parse(text)).map(\.id) == ["u1"], "\(text)")
            #expect(try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: .parse(text))).map(\.id) == ["u1"], "\(text)")
        }
        // Previews test label terms in SQL; the engine tests them in memory. Both agree.
        let filter = try RuleFilter.parse("label:ärzte")
        #expect(filter.labelTerms[0].labelIDs(in: try await store.labels()) == ["Label_9"])
        #expect(try await store.ruleMatches(filter, scope: .received) == ["u1"])
        #expect(try await store.ruleMatches(try RuleFilter.parse("-label:ärzte"), scope: .received, among: ["u1"]).isEmpty)
        #expect(try await store.contacts(matching: "émi").map(\.email) == ["emile@zola.fr"])
    }

    @Test func beforeAndAfterUseTheMessageDate() async throws {
        let store = try await messageQueryStore()
        var before = SearchQuery()
        before.before = Date().addingTimeInterval(-25 * 60)
        // m1 is 30 minutes old though its conversation's latest message (m2) is 20 minutes old.
        #expect(Set(try messageMatches(store, before).map(\.id)) == ["m1", "m4"])
        #expect(try await store.threads(ThreadQuery(scope: .anywhere).narrowed(by: before)).map(\.id) == ["t3"])

        var window = SearchQuery()
        window.after = Date().addingTimeInterval(-25 * 60)
        window.before = Date().addingTimeInterval(-3 * 60)
        #expect(Set(try messageMatches(store, window).map(\.id)) == ["m2", "m3"])
    }

    @Test func scopesKeepRulesOnReceivedMail() async throws {
        let store = try await messageQueryStore()
        try await store.setAccount(AccountProfile(email: me.email, displayName: "Sam Carter", historyCursor: "1", aliases: ["Sam@Alias.co"]))
        try await store.upsertMessages([
            message("s1", thread: "s1", subject: "Win a prize", labels: ["SPAM"], minutesAgo: 3),
            message("s2", thread: "s2", subject: "Old offer", labels: ["TRASH"], minutesAgo: 3),
            message("s3", thread: "s3", from: me, to: [nina], subject: "Draft", labels: ["DRAFT"], minutesAgo: 3),
            message("s4", thread: "s4", from: EmailAddress(name: "Sam", email: "sam@alias.co"), to: [nina], subject: "From my alias", labels: ["INBOX"], minutesAgo: 3),
        ])
        // An optimistic copy of a message still being sent.
        try store.writeNow { db, _ in
            try MailStore.insertLocalMessage(message("s5", thread: "s5", subject: "Sending", labels: ["INBOX"], minutesAgo: 3), db)
        }
        let all = try RuleFilter.parse("")
        #expect(Set(try await store.ruleMatches(all, scope: .received)) == ["m1", "m3", "m4", "m5", "m6"])
        #expect(Set(try await store.ruleMatches(all, scope: .inbox)) == ["m1", "m3", "m5", "m6"])
        #expect(try await store.ruleMatches(all, scope: .unsupported(json: "\"later\"")).isEmpty)
        #expect(try await store.ruleMatchCount(all, scope: .received) == 5)
    }

    @Test func ruleMatchesNarrowsByIDsWindowAndLimit() async throws {
        let store = try await messageQueryStore()
        let filter = try RuleFilter.parse("-label:work")
        #expect(try await store.ruleMatches(filter, scope: .received) == ["m6", "m5", "m3", "m1"])
        #expect(try await store.ruleMatches(filter, scope: .received, newestFirst: 2) == ["m6", "m5"])
        #expect(try await store.ruleMatches(filter, scope: .received, among: ["m1", "m4", "m5"]) == ["m5", "m1"])
        #expect(try await store.ruleMatches(filter, scope: .received, among: []).isEmpty)
        let window = Date().addingTimeInterval(-40 * 60)...Date().addingTimeInterval(-3 * 60)
        #expect(try await store.ruleMatches(filter, scope: .received, window: window) == ["m3", "m1"])
        // The engine tests label terms in memory: without them m4 (labeled work) passes too.
        #expect(try await store.ruleMatchCount(filter, scope: .received, labelTerms: false) == 5)
        #expect(try await store.ruleMatchCount(filter, scope: .received, labelTerms: true) == 4)
        // Long ID lists travel as one argument.
        let many = (0..<40_000).map { "x\($0)" } + ["m3"]
        #expect(try await store.ruleMatches(filter, scope: .received, among: many) == ["m3"])
    }
}
