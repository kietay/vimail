import Foundation

/// Answers to invitations by email (iMIP, RFC 6047), for invitations that are not on Google Calendar: the reply file
/// (METHOD:REPLY, RFC 5546) and the email that takes it to the organizer, whose calendar then records the answer.
extension ICalendar {
    /// An iMIP reply (METHOD:REPLY, RFC 5546) that answers `invitation` as `attendee`: the file to mail
    /// to the organizer. Times are written in UTC and all-day dates as dates, so it needs no VTIMEZONE.
    /// Lines end in CRLF and are folded at 75 octets.
    public static func reply(to invitation: Invitation, as attendee: Attendee, response: ResponseStatus, comment: String?, stamp: Date) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "PRODID:-//vimail//EN", "VERSION:2.0", "METHOD:REPLY", "BEGIN:VEVENT",
            "UID:" + escapedText(invitation.uid),
            "SEQUENCE:\(invitation.sequence)",
            "DTSTAMP:" + utcText(stamp),
        ]
        if let recurrenceID = invitation.recurrenceID { lines.append("RECURRENCE-ID" + timeValue(recurrenceID)) }
        lines.append("DTSTART" + timeValue(invitation.start))
        if let end = invitation.end { lines.append("DTEND" + timeValue(end)) }
        lines.append("SUMMARY:" + escapedText(invitation.summary))
        if let organizer = invitation.organizer {
            lines.append("ORGANIZER" + nameParameter(organizer.name) + ":mailto:" + addressText(organizer.email))
        }
        lines.append("ATTENDEE;PARTSTAT=" + response.partstat + nameParameter(attendee.name) + ":mailto:" + addressText(attendee.email))
        if let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            lines.append("COMMENT:" + escapedText(comment))
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(folded).joined(separator: "\r\n") + "\r\n"
    }

    /// The email that answers `invitation`: from you to the organizer, in the conversation of the invitation's `mail`,
    /// with one line of text and your note, and the reply as a `text/calendar` part the organizer's calendar reads.
    /// Nil when the invitation cannot be answered by email (`Invitation.canBeAnsweredByEmail`) or `response` is no answer.
    /// `selfAddresses` are your addresses (lowercased); times in the subject use the event's zone, else `timeZone`.
    public static func replyMail(
        to invitation: Invitation, mail: MailMessage?, account: EmailAddress, selfAddresses: Set<String>,
        response: ResponseStatus, comment: String?, now: Date = Date(), timeZone: TimeZone = .current
    ) -> OutgoingMessage? {
        guard response != .needsAction, invitation.canBeAnsweredByEmail(by: selfAddresses), let organizer = invitation.organizer else { return nil }
        let attendee = replyAttendee(for: invitation, account: account, selfAddresses: selfAddresses)
        let note = comment.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        // Names come from the invitation's file: in a header they stay on one line.
        let from = EmailAddress(name: attendee.name.map(oneLine), email: attendee.email)
        var references = mail?.references ?? []
        if let header = mail?.messageIDHeader, !references.contains(header) { references.append(header) }
        // Fixed now, so a retry after a timeout can find the copy that already went out.
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "vimail.local"
        return OutgoingMessage(
            from: from, to: [EmailAddress(name: organizer.name.map(oneLine), email: organizer.email)],
            subject: replySubject(for: invitation, response: response, timeZone: timeZone),
            textBody: replyText(from: from, response: response, comment: note),
            threadID: mail?.threadID, inReplyTo: mail?.messageIDHeader, references: references,
            messageID: "<vimail.\(UUID().uuidString.lowercased())@\(domain)>",
            calendar: CalendarPart(method: Invitation.Method.reply.rawValue, text: reply(to: invitation, as: attendee, response: response, comment: note, stamp: now))
        )
    }

    /// You, as the reply names you: the address the invitation was sent to when it is one of yours, spelled as the
    /// invitation spells it (the organizer's calendar knows that one), else the account's address. The name is the account's.
    static func replyAttendee(for invitation: Invitation, account: EmailAddress, selfAddresses: Set<String>) -> Attendee {
        let invited = invitation.attendee(matching: selfAddresses.union([account.normalized]))
        return Attendee(email: invited?.email ?? account.email, name: account.name ?? invited?.name)
    }

    /// "Accepted: Design review @ Mon Oct 12, 2026 2pm - 2:45pm (PDT)", as Google Calendar words its answers.
    static func replySubject(for invitation: Invitation, response: ResponseStatus, timeZone: TimeZone) -> String {
        let verb = replyVerb(response)
        return verb.prefix(1).uppercased() + String(verb.dropFirst()) + ": \(oneLine(invitation.summary)) @ \(replyWhen(invitation, timeZone: timeZone))"
    }

    /// "Sam Carter has accepted this invitation.", and the note below it.
    static func replyText(from sender: EmailAddress, response: ResponseStatus, comment: String?) -> String {
        let line = "\(sender.displayName) has \(replyVerb(response)) this invitation."
        guard let comment, !comment.isEmpty else { return line }
        return line + "\n\n" + comment
    }

    /// "accepted", "tentatively accepted", "declined".
    static func replyVerb(_ response: ResponseStatus) -> String {
        switch response {
        case .accepted: "accepted"
        case .tentative: "tentatively accepted"
        case .declined: "declined"
        case .needsAction: "not answered"
        }
    }

    /// When the event is, as Google writes it in answers: "Mon Oct 12, 2026 2pm - 2:45pm (PDT)", "Mon Oct 12, 2026",
    /// "Fri Oct 16 - Sun Oct 18, 2026". Times are in the event's own zone (usually the organizer's); UTC times and
    /// unknown zones are in `timeZone`. A series says how it repeats, as its first date may be long past: "Weekly on
    /// Mon from 2pm to 2:45pm (Pacific Time)", "Yearly on Oct 12".
    static func replyWhen(_ invitation: Invitation, timeZone fallback: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        func text(_ date: Date, _ format: String) -> String {
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        func repeats(in calendar: Calendar) -> String? {
            invitation.recurrenceID == nil ? Recurrence.summary(invitation.recurrence, start: invitation.start, calendar: calendar) : nil
        }

        if case .allDay(let first) = invitation.start {
            if let rule = repeats(in: utcCalendar) { return rule }
            formatter.timeZone = .gmt
            var last = first
            if case .allDay(let after)? = invitation.end { last = after.adding(days: -1, in: utcCalendar) }
            let firstDate = first.start(in: utcCalendar)
            guard last > first else { return text(firstDate, "EEE MMM d, yyyy") }
            return text(firstDate, first.year == last.year ? "EEE MMM d" : "EEE MMM d, yyyy") + " - " + text(last.start(in: utcCalendar), "EEE MMM d, yyyy")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = invitation.start.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallback
        formatter.timeZone = calendar.timeZone
        func clock(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let hour = parts.hour ?? 0, minute = parts.minute ?? 0
            return "\(hour % 12 == 0 ? 12 : hour % 12)" + (minute == 0 ? "" : String(format: ":%02d", minute)) + (hour < 12 ? "am" : "pm")
        }
        let start = invitation.start.instant(in: calendar)
        // An end at midnight closes the start's day.
        let end = invitation.end.map { $0.instant(in: calendar) }.flatMap { $0 > start ? $0 : nil }
        let sameDay = end.map { calendar.isDate($0.addingTimeInterval(-1), inSameDayAs: start) } ?? false
        if let rule = repeats(in: calendar) {
            // The zone's name for every season: a series outlives daylight saving time.
            return rule + " from " + clock(start) + (sameDay ? " to " + clock(end!) : "") + " (" + text(start, "vvvv") + ")"
        }
        var result = text(start, "EEE MMM d, yyyy") + " " + clock(start)
        if let end {
            result += " - " + (sameDay ? "" : text(end, "EEE MMM d, yyyy") + " ") + clock(end)
        }
        return result + " (" + text(start, "zzz") + ")"
    }
}

extension Invitation {
    /// True when an answer can go to the organizer by email (iMIP): a request that is not cancelled, from an
    /// organizer with a plain address (`ICalendar.isMailable`) that is not one of `me` (your addresses, lowercased).
    public func canBeAnsweredByEmail(by me: Set<String>) -> Bool {
        guard method == .request, !isCancellation, let organizer, ICalendar.isMailable(organizer.email) else { return false }
        return !organizer.isSelf && !me.contains(organizer.normalized)
    }
}

// MARK: - Writing

extension ICalendar {
    /// An address an answer can be mailed to as written: one `@` with text on both sides and a dot inside the domain,
    /// and no spaces, control characters or characters that quote or separate addresses in a header. The organizer's
    /// address comes from the invitation's sender, so it must not be able to add recipients or headers.
    public static func isMailable(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        let separators = Set("<>()[],;:\\\"".unicodeScalars)
        return !email.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control || separators.contains($0) }
    }

    /// Text for one header line: line breaks, tabs and other control characters become spaces, and runs of spaces one.
    static func oneLine(_ text: String) -> String {
        text.unicodeScalars.split { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    /// What follows a time property's name: `;VALUE=DATE:20261012` or `:20261012T210000Z`.
    static func timeValue(_ time: EventTime) -> String {
        switch time {
        case .allDay(let day): String(format: ";VALUE=DATE:%04d%02d%02d", day.year, day.month, day.day)
        case .timed(let date, _): ":" + utcText(date)
        }
    }

    /// TEXT escaping: backslashes, semicolons, commas and line breaks, with other control characters
    /// except tabs dropped, as TEXT does not allow them.
    static func escapedText(_ text: String) -> String {
        var result = ""
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case ";": result += "\\;"
            case ",": result += "\\,"
            case "\n", "\r": result += "\\n"
            default: if scalar == "\t" || scalar.properties.generalCategory != .control { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    /// `;CN=Jamie Chen`, or nothing without a name.
    static func nameParameter(_ name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "" }
        return ";CN=" + parameterValue(name)
    }

    /// An address for a `mailto:` value, without characters that could start a new line in the file.
    static func addressText(_ email: String) -> String {
        let kept = email.unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }

    /// Folds a content line so no physical line is longer than 75 octets, breaking only between Unicode
    /// scalars so that no UTF-8 sequence is split.
    static func folded(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var result = String.UnicodeScalarView()
        var length = 0
        for scalar in line.unicodeScalars {
            let size = UTF8.width(scalar)
            if length + size > 75 {
                result.append(contentsOf: "\r\n ".unicodeScalars)
                length = 1
            }
            result.append(scalar)
            length += size
        }
        return String(result)
    }
}
