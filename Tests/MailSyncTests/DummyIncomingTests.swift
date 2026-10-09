import Foundation
import Testing
@testable import DummyProvider
@testable import MailCore
@testable import MailSync

@Suite("Simulated incoming mail")
struct DummyIncomingTests {
    /// What kind of mail an incoming message is, by its sender and headers.
    func kind(_ message: MailMessage) -> String {
        if message.from.normalized == DummyContent.stripe.address.normalized { return "receipt" }
        if message.from.normalized == DummyContent.calendar.address.normalized { return "invite" }
        if message.listUnsubscribe != nil { return "newsletter" }
        if DummyContent.people.contains(where: { $0.address.normalized == message.from.normalized }) { return "person" }
        return "notification"
    }

    @Test func includesReceiptsNewslettersAndInvites() {
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        var counts: [String: Int] = [:]
        for seed in 1...300 {
            var generator = DummyGenerator(seed: UInt64(seed), now: now)
            var next = 0
            let messages = generator.incomingMessages(account: DummyContent.account, existing: [], labels: [], newID: {
                next += 1
                return "incoming-\(seed)-\(next)"
            })
            #expect(messages.count == 1)
            for message in messages {
                counts[kind(message), default: 0] += 1
                #expect(message.date == now)
                #expect(message.threadID == message.id)
                #expect(message.labelIDs.isSuperset(of: [SystemLabel.inbox, SystemLabel.unread]))
                #expect(message.from.normalized != DummyContent.account.normalized)
            }
        }
        for kind in ["receipt", "newsletter", "invite", "notification", "person"] {
            #expect(counts[kind, default: 0] >= 15, "too few \(kind)s: \(counts)")
        }
    }
}
