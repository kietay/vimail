import Foundation
import MailCore

/// An event's Notes are Markdown, written with the compose body's keys. Once they change, Google gets them as HTML
/// rendered the way compose renders a message; until then the description stays exactly as Google has it, with its
/// formatting and links.
public enum EventNotes {
    /// The description a save sends. `opened` is Notes as the editor showed it, `stored` the description as stored.
    /// Changes only to spaces and blank lines at either end are no change.
    public static func description(notes: String, opened: String, stored: String?) -> String? {
        guard trimmed(notes) != trimmed(opened) else { return stored }
        return html(notes)
    }

    /// Markdown notes as HTML, or nil when there are none.
    public static func html(_ notes: String) -> String? {
        trimmed(notes).isEmpty ? nil : Markdown.html(notes)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
