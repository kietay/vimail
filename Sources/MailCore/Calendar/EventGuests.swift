import Foundation

/// Guests as the event editor holds them: finished guests are addresses (pills), then the text being typed. A name stays
/// typed until it is picked from the suggestions, or looked up in the contacts when the event is saved.
public enum EventGuests {
    /// The pills for an event's guests: its attendees without you (your addresses, or the calendar's own entry) and
    /// without rooms. Those stay on the event without showing.
    public static func pills(of attendees: [Attendee], me: Set<String>) -> [EmailAddress] {
        attendees.filter { !$0.isSelf && !$0.isResource && !me.contains($0.normalized) }.map(\.address).deduplicated()
    }

    /// `guests`, then the `added` ones that are new: each address once, and never one of yours.
    public static func adding(_ added: [EmailAddress], to guests: [EmailAddress], me: Set<String>) -> [EmailAddress] {
        guests + added.filter { !me.contains($0.normalized) }.deduplicated(excluding: Set(guests.map(\.normalized)))
    }

    /// Splits what is typed in Guests. A full address followed by a comma or semicolon, or closed with ">", is finished.
    /// Names stay typed, and so does the part after the last comma. `finishing` (↵, tab, the cursor leaving Guests)
    /// finishes that last part too, when it is a full address.
    public static func split(_ typed: String, finishing: Bool = false) -> (finished: [EmailAddress], typing: String) {
        var parts = parts(typed)
        var open = String(parts.removeLast().drop(while: \.isWhitespace))
        var finished: [EmailAddress] = []
        var names: [String] = []
        for part in parts {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let address = EmailAddress.parse(text), address.isValid { finished.append(address) } else { names.append(text) }
        }
        if finishing || open.trimmingCharacters(in: .whitespaces).hasSuffix(">"), let address = EmailAddress.parse(open), address.isValid {
            finished.append(address)
            open = ""
        }
        if names.isEmpty { return (finished, open) }
        let kept = names.joined(separator: ", ")
        return (finished, finishing && open.isEmpty ? kept : "\(kept), \(open)")
    }

    /// The part after the last comma or semicolon: what the suggestions match.
    public static func token(_ typed: String) -> String {
        (parts(typed).last ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The typed text without its last part, which a picked suggestion replaces.
    public static func droppingToken(_ typed: String) -> String {
        let names = parts(typed).dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? "" : names.joined(separator: ", ") + ", "
    }

    /// Names typed in Guests (not addresses): they are looked up in the contacts. Commas inside quotes
    /// ("Chen, Jamie" <jamie@studio.co>) do not split.
    public static func names(_ typed: String) -> [String] {
        EmailAddress.parseList(typed).filter { !$0.isValid }.map(\.email).filter { !$0.isEmpty }
    }

    /// The guests a save gets: the pills, then what is still typed, addresses as they are and names as their best match in
    /// `contacts`. `unknown` lists the names that match nobody: a save stops on them rather than drop them.
    public static func resolve(
        _ guests: [EmailAddress], typed: String, me: Set<String>, contacts: (String) -> [EmailAddress]
    ) -> (guests: [EmailAddress], unknown: [String]) {
        var resolved = guests
        var unknown: [String] = []
        for entry in EmailAddress.parseList(typed) {
            if entry.isValid {
                resolved = adding([entry], to: resolved, me: me)
            } else if !entry.email.isEmpty {
                if let match = contacts(entry.email).first { resolved = adding([match], to: resolved, me: me) } else { unknown.append(entry.email) }
            }
        }
        return (resolved, unknown)
    }

    /// The same people, in any order.
    public static func same(_ guests: [EmailAddress], _ others: [EmailAddress]) -> Bool {
        Set(guests.map(\.normalized)) == Set(others.map(\.normalized))
    }

    /// The parts of `typed` between commas or semicolons outside quotes and angle brackets, the last one included even
    /// when empty.
    private static func parts(_ typed: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var previous: Character = " "
        for char in typed {
            switch char {
            case "\"" where previous != "\\": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            default: break
            }
            if (char == "," || char == ";") && !inQuotes && !inAngle {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        parts.append(current)
        return parts
    }
}
