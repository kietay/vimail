import SwiftUI

extension View {
    /// Gives single-line text the height of a CSS line box, so spacing matches the web design
    /// (Tailwind's default line-height is 1.5; `text-xs` uses 16px).
    func cssLine(_ fontSize: CGFloat, _ lineHeight: CGFloat = 1.5) -> some View {
        frame(minHeight: (fontSize * lineHeight).rounded(.toNearestOrAwayFromZero))
    }
}

private struct HintsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Key hints show on hover (as in the design) or always, per settings.
    var hintsVisible: Bool {
        get { self[HintsVisibleKey.self] }
        set { self[HintsVisibleKey.self] = newValue }
    }
}

/// Shows key hints inside this view while the pointer is over it.
struct HintScope: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .environment(\.hintsVisible, hovering || model.settings.alwaysShowKeyHints)
    }
}

extension View {
    func hintScope() -> some View { modifier(HintScope()) }
}

/// The design's `<Key>` chip.
struct KeyChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.hintsVisible) private var hintsVisible
    let text: String
    var dark = false
    var alwaysVisible = false

    init(_ text: String, dark: Bool = false, alwaysVisible: Bool = false) {
        self.text = text
        self.dark = dark
        self.alwaysVisible = alwaysVisible
    }

    var body: some View {
        Text(text)
            .font(AppFonts.mono(10))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .foregroundStyle(dark ? theme.buttonText.opacity(0.75) : theme.mutedForeground)
            .background(dark ? Color.clear : theme.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(dark ? theme.buttonText.opacity(0.3) : theme.border, lineWidth: 1))
            .opacity(alwaysVisible || hintsVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hintsVisible)
    }
}

/// A square icon button (header, list, reader toolbars).
struct IconButton: View {
    @Environment(\.theme) private var theme
    let icon: IconName
    var size: CGFloat = 17
    var frame: CGFloat = 32
    var help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: size)
                .frame(width: frame, height: frame)
                .foregroundStyle(hovering || active ? theme.foreground : theme.mutedForeground)
                .background(hovering || active ? theme.muted : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A label chip, as in the list rows and reader.
struct LabelChip: View {
    @Environment(\.theme) private var theme
    let name: String
    let colorIndex: Int

    var body: some View {
        let colors = theme.labelColor(colorIndex)
        Text(name)
            .font(AppFonts.mono(9))
            .lineLimit(1)
            .cssLine(9)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(colors.fg)
            .background(colors.soft, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The design's dialog: rounded card, title bar with a close button, and a footer.
struct DialogShell<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var width: CGFloat = 560
    var footer: String? = "esc to close"
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(AppFonts.mono(12)).foregroundStyle(theme.foreground)
                Spacer()
                CloseButton(action: onClose)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rectangle().fill(theme.border).frame(height: 1)
            content
            if let footer {
                Rectangle().fill(theme.border).frame(height: 1)
                Text(footer)
                    .font(AppFonts.mono(9))
                    .foregroundStyle(theme.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: width)
        .background(theme.reader.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border.opacity(0.8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 50, y: 24)
    }
}

/// The dialog close "x" with a comfortable 28pt target.
struct CloseButton: View {
    @Environment(\.theme) private var theme
    var help = "Close (esc)"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(name: .close, size: 16)
                .foregroundStyle(hovering ? theme.foreground : theme.mutedForeground)
                .frame(width: 28, height: 28)
                .background(hovering ? theme.muted : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(-6)
        .help(help)
    }
}

/// A plain text field styled like the design's inputs.
struct FieldStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(AppFonts.sans(12))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}

/// Hover background for rows and menu items.
struct HoverHighlight: ViewModifier {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat = 6
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(active ? theme.selected : (hovering ? theme.muted : .clear), in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6, active: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, active: active))
    }
}
