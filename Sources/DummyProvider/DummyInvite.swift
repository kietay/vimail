import Foundation
import MailCore

/// A meeting that a dummy invitation mail is about. The invitation's text, its `invite.ics` file and the
/// dummy calendar's event all come from it, so mail and calendar agree, as they do with Google.
public struct DummyInvite: Codable, Hashable, Sendable {
    public var uid: String
    public var messageID: String
    public var title: String
    public var start: Date
    public var minutes: Int
    public var organizer: EmailAddress
    /// Everyone invited, including the account.
    public var guests: [EmailAddress]
    /// Guests who already said yes (lowercased addresses).
    public var accepted: [String]
    public var conference: String?
    public var agenda: String?
    public var sequence: Int
    /// When the invitation was sent.
    public var sent: Date

    public var end: Date { start.addingTimeInterval(Double(minutes) * 60) }

    /// The `invite.ics` file Google attaches to an invitation (METHOD:REQUEST), in the Mac's time zone.
    public func icsFile(timeZone: TimeZone = .current) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        local.dateFormat = "yyyyMMdd'T'HHmmss"
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "DTSTART;TZID=\(timeZone.identifier):\(local.string(from: start))",
            "DTEND;TZID=\(timeZone.identifier):\(local.string(from: end))",
            "DTSTAMP:\(utc.string(from: sent))",
            "ORGANIZER;CN=\(organizer.displayName):mailto:\(organizer.email)",
            "UID:\(uid)",
        ]
        for guest in guests {
            let answer = guest.normalized == organizer.normalized || accepted.contains(guest.normalized) ? "ACCEPTED" : "NEEDS-ACTION"
            lines.append("ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=\(answer);RSVP=TRUE;CN=\(guest.displayName);X-NUM-GUESTS=0:mailto:\(guest.email)")
        }
        if let conference { lines.append("X-GOOGLE-CONFERENCE:\(conference)") }
        lines += [
            "CREATED:\(utc.string(from: sent))",
            "DESCRIPTION:\(escaped(agenda ?? ""))",
            "LAST-MODIFIED:\(utc.string(from: sent))",
            "LOCATION:",
            "SEQUENCE:\(sequence)",
            "STATUS:CONFIRMED",
            "SUMMARY:\(escaped(title))",
            "TRANSP:OPAQUE",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
