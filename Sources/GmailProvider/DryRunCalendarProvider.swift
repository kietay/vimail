import Foundation
import MailCore
import VimailLog

/// Wraps a calendar provider so a real calendar can be used for testing without changing it.
/// Reads go to the real provider. Answers, creates, edits and removals never leave this Mac: they
/// succeed locally, and each one is logged to `calendar.log` in `directory`.
public actor DryRunCalendarProvider: CalendarProvider {
    private let base: any CalendarProvider
    public let directory: URL

    public nonisolated var kind: String { base.kind }

    public init(wrapping base: any CalendarProvider, directory: URL) {
        self.base = base
        self.directory = directory
    }

    public func calendars(syncToken: String?, pageToken: String?) async throws -> CalendarListPage {
        try await base.calendars(syncToken: syncToken, pageToken: pageToken)
    }

    public func events(calendarID: String, syncToken: String?, pageToken: String?, timeMin: Date?) async throws -> EventPage {
        try await base.events(calendarID: calendarID, syncToken: syncToken, pageToken: pageToken, timeMin: timeMin)
    }

    public func instances(calendarID: String, eventID: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        try await base.instances(calendarID: calendarID, eventID: eventID, from: from, to: to)
    }

    public func event(calendarID: String, eventID: String) async throws -> CalendarEvent? {
        try await base.event(calendarID: calendarID, eventID: eventID)
    }

    public func freeBusy(emails: [String], from: Date, to: Date) async throws -> [String: [DateInterval]] {
        try await base.freeBusy(emails: emails, from: from, to: to)
    }

    public nonisolated func changeSignals() -> AsyncStream<Void> { base.changeSignals() }

    public func insert(_ event: CalendarEvent, sendUpdates: SendUpdates, addConference: Bool) async throws -> CalendarEvent {
        log("insert \(event.id) guests=\(event.attendees.count) conference=\(addConference) updates=\(sendUpdates.rawValue)")
        var created = event
        created.etag = "\"dryrun\""
        if addConference, created.conferenceURL == nil { created.conferenceURL = "https://meet.google.com/dry-run" }
        return created
    }

    public func events(calendarID: String, iCalUID: String) async throws -> [CalendarEvent] {
        try await base.events(calendarID: calendarID, iCalUID: iCalUID)
    }

    public func update(_ event: CalendarEvent, previous: CalendarEvent?, etag: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        log("update \(event.id) etag=\(etag ?? "none") updates=\(sendUpdates.rawValue)")
        return event
    }

    public func delete(calendarID: String, eventID: String, sendUpdates: SendUpdates) async throws {
        log("delete \(eventID) updates=\(sendUpdates.rawValue)")
    }

    public func respond(calendarID: String, eventID: String, response: ResponseStatus, comment: String?, sendUpdates: SendUpdates) async throws -> CalendarEvent {
        log("respond \(eventID) \(response.rawValue)\(comment == nil ? "" : " with a note") updates=\(sendUpdates.rawValue)")
        guard var event = try await base.event(calendarID: calendarID, eventID: eventID) else { throw ProviderError.notFound("event") }
        if let index = event.attendees.firstIndex(where: \.isSelf) {
            event.attendees[index].response = response
            event.attendees[index].comment = comment
        }
        return event
    }

    private func log(_ line: String) {
        Log("dry-run").info("Not sent to Google Calendar: \(line)")
        let url = directory.appendingPathComponent("calendar.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: url)
        }
    }
}
