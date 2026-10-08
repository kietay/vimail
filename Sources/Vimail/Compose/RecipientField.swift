import MailCore
import SwiftUI

/// A finished recipient in To, Cc or Bcc. Click it to remove it. Invalid addresses show red.
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
