import Foundation
import Testing
@testable import MailCore
@testable import VimailKit

@Suite("Event notes")
struct EventNotesTests {
    /// A description as Google Calendar writes it, with a link.
    let stored = #"Agenda:<br><ul><li>Budget</li></ul><a href="https://docs.example.com/q3">the doc</a>"#

    @Test func unchangedNotesKeepTheDescriptionExactly() {
        let shown = HTMLText.editableText(stored)
        #expect(EventNotes.description(notes: shown, opened: shown, stored: stored) == stored)
        // Spaces or blank lines added at either end are no change.
        #expect(EventNotes.description(notes: shown + "\n\n", opened: shown, stored: stored) == stored)
        #expect(EventNotes.description(notes: "", opened: "", stored: nil) == nil)
    }

    @Test func changedNotesAreMarkdownRenderedAsCompose() {
        let notes = "Bring the **numbers**.\n\n- budget\n- hiring"
        let description = EventNotes.description(notes: notes, opened: "Bring numbers.", stored: "<p>Bring numbers.</p>")
        #expect(description == Markdown.html(notes))
        #expect(description?.contains("<strong>numbers</strong>") == true)
        #expect(description?.contains("<ul") == true)
        // Typed into a new event.
        #expect(EventNotes.description(notes: "See https://example.com/a", opened: "", stored: nil)?.contains(#"<a href="https://example.com/a""#) == true)
    }

    @Test func clearedNotesClearTheDescription() {
        #expect(EventNotes.description(notes: " \n", opened: "Agenda", stored: "<p>Agenda</p>") == nil)
        #expect(EventNotes.html("") == nil)
    }

    @Test func notesNeverCarryRawHTML() {
        #expect(EventNotes.html("<img src=x onerror=alert(1)>")?.contains("<img") == false)
    }
}
