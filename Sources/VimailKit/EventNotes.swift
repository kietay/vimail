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

    /// A description as a page shows it: HTML as it is, plain text with its line breaks.
    public static func displayHTML(_ description: String?) -> String {
        guard let description, !trimmed(description).isEmpty else { return "" }
        if HTMLText.looksLikeHTML(description) { return description }
        return HTMLText.escape(description).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// What guests see, for the event editor's preview: the title, when (and how it repeats), where and the join link,
    /// then the notes. `description` is the one a save sends. A join link that is not a web link shows as nothing.
    public static func preview(
        title: String, when: String?, repeats: String?, place: String?, joinLink: String?, joinNote: String?, description: String?
    ) -> String {
        var rows: [(label: String, html: String)] = []
        var time = when.map(HTMLText.escape) ?? muted("No time yet")
        if let repeats, !repeats.isEmpty { time += "<br>" + muted(repeats) }
        rows.append(("When", time))
        if let place, !trimmed(place).isEmpty { rows.append(("Where", HTMLText.escape(trimmed(place)))) }
        if let link = ICalendar.webLink(joinLink) {
            rows.append(("Join", "<a href=\"\(HTMLText.escape(link))\" style=\"\(Markdown.Style.link)\">\(HTMLText.escape(shortLink(link)))</a>"))
        } else if let joinNote {
            rows.append(("Join", muted(joinNote)))
        }
        let table = rows.map { "<tr><td style=\"\(Style.label)\">\($0.label)</td><td style=\"\(Style.value)\">\($0.html)</td></tr>" }.joined()
        let notes = displayHTML(description)
        let heading = trimmed(title).isEmpty ? "(no title)" : title
        return "<div style=\"\(EmailComposer.wrapperStyle)\"><h2 style=\"\(Style.title)\">\(HTMLText.escape(heading))</h2>"
            + "<table style=\"\(Style.table)\">\(table)</table>"
            + (notes.isEmpty ? "" : "<div style=\"\(Style.notes)\">\(notes)</div>")
            + "</div>"
    }

    private enum Style {
        static let title = "font-size:20px;font-weight:600;margin:0 0 12px 0;line-height:1.3;"
        static let table = "border-collapse:collapse;margin:0 0 16px 0;"
        static let label = "padding:3px 18px 3px 0;color:#57606a;vertical-align:top;white-space:nowrap;"
        static let value = "padding:3px 0;vertical-align:top;"
        static let muted = "color:#57606a;"
        static let notes = "border-top:1px solid #d0d7de;padding-top:14px;"
    }

    /// Plain text in the muted color.
    private static func muted(_ text: String) -> String {
        "<span style=\"\(Style.muted)\">\(HTMLText.escape(text))</span>"
    }

    /// "meet.google.com/abc-defg-hij": a link without its scheme and query.
    private static func shortLink(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        return host + url.path
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
