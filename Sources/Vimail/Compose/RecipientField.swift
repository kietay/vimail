import MailCore
import SwiftUI

/// Finished addresses as pills, then the text field for the one being typed: compose's To, Cc and Bcc, and the event
/// editor's Guests. A click anywhere on it puts the cursor in the field.
struct RecipientInput: View {
    @Environment(\.theme) private var theme
    let addresses: [EmailAddress]
    @Binding var text: String
    /// Shown while there are no pills.
    let prompt: String
    let field: FocusTarget
    var focus: FocusState<FocusTarget?>.Binding
    var fontSize: CGFloat = 13
    let remove: (EmailAddress) -> Void

    var body: some View {
        RecipientFlow {
            ForEach(addresses, id: \.normalized) { address in
                RecipientPill(address: address) { remove(address) }
            }
            TextField("", text: $text, prompt: addresses.isEmpty ? Text(prompt).foregroundColor(theme.mutedForeground.opacity(0.6)) : nil)
                .textFieldStyle(.plain)
                .font(AppFonts.sans(fontSize))
                .foregroundStyle(theme.foreground)
                .focused(focus, equals: field)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
    }
}

/// Contacts that match what is typed, in a list under the address field. ↑ ↓ move, ↵ or tab (or a click) takes one.
struct RecipientSuggestions: View {
    @Environment(\.theme) private var theme
    let suggestions: [EmailAddress]
    let highlighted: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.normalized) { index, address in
                HStack(spacing: 10) {
                    Text(address.initials).font(AppFonts.mono(9)).foregroundStyle(theme.mutedForeground)
                        .frame(width: 22, height: 22).background(theme.muted, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(address.displayName).font(AppFonts.sans(12)).foregroundStyle(theme.foreground)
                        if address.name != nil { Text(address.email).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(index == highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { pick(index) }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(theme.reader, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

/// A finished recipient in To, Cc or Bcc, or a guest of an event. Click it to remove it. Invalid addresses show red.
struct RecipientPill: View {
    @Environment(\.theme) private var theme
    let address: EmailAddress
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(address.displayName)
                    .font(AppFonts.sans(12))
                    .foregroundStyle(address.isValid ? theme.foreground : theme.red)
                    .lineLimit(1)
                Icon(name: .close, size: 8)
                    .foregroundStyle(theme.mutedForeground.opacity(hovering ? 1 : 0.55))
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: RecipientFlow.lineHeight)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(address.isValid ? "\(address.formatted) · click to remove" : "Not a valid address · click to remove")
    }

    private var background: Color {
        if !address.isValid { return theme.redSoft }
        return hovering ? theme.selected : theme.muted.opacity(0.8)
    }
}

/// Pills left to right, wrapping onto new lines. The last view (the text field) takes the rest of
/// its line, or a new line when less than `minFieldWidth` is left.
struct RecipientFlow: Layout {
    static let lineHeight: CGFloat = 22
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var minFieldWidth: CGFloat = 140

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: frames(width: width, subviews: subviews).last?.maxY ?? Self.lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let isField = index == subviews.count - 1
            var itemWidth = min(subview.sizeThatFits(.unspecified).width, width)
            let needed = isField ? minFieldWidth : itemWidth
            if x > 0, x + needed > width {
                x = 0
                y += Self.lineHeight + lineSpacing
            }
            if isField { itemWidth = width - x }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: Self.lineHeight))
            x += itemWidth + spacing
        }
        return frames
    }
}
