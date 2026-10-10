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

    /// Esc's draft and "this and following" ask the same question a save does: your editor's newline is no change.
    @Test func onlyChangesInsideTheNotesCount() {
        #expect(!EventNotes.changed("Agenda\n- budget", from: "Agenda\n- budget\n"))
        #expect(!EventNotes.changed("  Agenda\n\n", from: "Agenda"))
        #expect(EventNotes.changed("Agenda\n\n- budget", from: "Agenda\n- budget"))
        #expect(EventNotes.changed("", from: "Agenda"))
        #expect(!EventNotes.changed(" \n", from: ""))
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

    @Test func aDescriptionShowsAsHTMLOrAsTextWithItsLines() {
        #expect(EventNotes.displayHTML(stored) == stored)
        #expect(EventNotes.displayHTML("Budget < 5k\nAlex <alex@example.com>") == "Budget &lt; 5k<br>Alex &lt;alex@example.com&gt;")
        #expect(EventNotes.displayHTML(nil) == "")
        #expect(EventNotes.displayHTML(" \n") == "")
    }

    @Test func thePreviewShowsWhatGuestsSee() {
        let html = EventNotes.preview(
            title: "Q3 <plan>", when: "Mon Oct 12 · 14:00–14:45", repeats: "Weekly on Monday", place: "Room 4 & 5",
            joinLink: "https://meet.google.com/abc-defg-hij?authuser=0", joinNote: nil, description: Markdown.html("Bring the **numbers**.")
        )
        #expect(html.contains("Q3 &lt;plan&gt;</h2>"))
        #expect(html.contains("Mon Oct 12 · 14:00–14:45"))
        #expect(html.contains("Weekly on Monday"))
        #expect(html.contains("Room 4 &amp; 5"))
        #expect(html.contains(#"<a href="https://meet.google.com/abc-defg-hij?authuser=0""#))
        #expect(html.contains(">meet.google.com/abc-defg-hij</a>"))
        #expect(html.contains("<strong>numbers</strong>"))
    }

    @Test func thePreviewSaysWhatIsMissing() {
        let html = EventNotes.preview(
            title: " ", when: nil, repeats: nil, place: "", joinLink: "javascript:alert(1)", joinNote: "A Google Meet link is added when you save.",
            description: nil
        )
        #expect(html.contains("(no title)"))
        #expect(html.contains("No time yet"))
        #expect(!html.contains("Where"))
        #expect(!html.contains("javascript"))
        #expect(html.contains("A Google Meet link is added when you save."))
        #expect(!html.contains("border-top"))
    }
}
