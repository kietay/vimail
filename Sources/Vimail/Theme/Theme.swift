import AppKit
import CoreText
import SwiftUI

/// Colors from the design's theme.css, plus three extra label colors per theme.
struct Palette: Equatable {
    var isDark: Bool
    var background, foreground, border, primary, primaryForeground: String
    var muted, mutedForeground, sidebar, list, reader, selected: String
    var green, greenSoft, orange, orangeSoft, purple, purpleSoft, yellow, yellowSoft: String
    var aqua, aquaSoft, blue, blueSoft, red, redSoft: String
    var body, button, buttonText, status, statusText, statusBright, mode, modeText, selection: String

    static let gruvbox = Palette(
        isDark: true,
        background: "#282828", foreground: "#ebdbb2", border: "#45413a", primary: "#fe8019", primaryForeground: "#282828",
        muted: "#353330", mutedForeground: "#afa491", sidebar: "#242424", list: "#282828", reader: "#2d2c29", selected: "#373b31",
        green: "#b2bb82", greenSoft: "#34392e", orange: "#fe8019", orangeSoft: "#443427", purple: "#d3869b", purpleSoft: "#41323a",
        yellow: "#d5b66d", yellowSoft: "#423b28",
        aqua: "#8ec07c", aquaSoft: "#2f3a2e", blue: "#83a598", blueSoft: "#2c3634", red: "#fb4934", redSoft: "#462a26",
        body: "#d5c4a1", button: "#49483e", buttonText: "#ebdbb2", status: "#1d2021", statusText: "#bdae93", statusBright: "#ebdbb2",
        mode: "#41483a", modeText: "#c6d0ad", selection: "#665c54"
    )

    static let papercolor = Palette(
        isDark: false,
        background: "#eeeeee", foreground: "#444444", border: "#dddfdc", primary: "#d75f00", primaryForeground: "#eeeeee",
        muted: "#e7e9e6", mutedForeground: "#767676", sidebar: "#e9ebe7", list: "#f2f3f0", reader: "#fafbf8", selected: "#e1ebe5",
        green: "#36785e", greenSoft: "#e1ebe5", orange: "#af5f00", orangeSoft: "#eddfcb", purple: "#875faf", purpleSoft: "#e4dcec",
        yellow: "#875f00", yellowSoft: "#e8e1ce",
        aqua: "#00876c", aquaSoft: "#d6ebe5", blue: "#005f87", blueSoft: "#d9e5ee", red: "#af0000", redSoft: "#f0dbd9",
        body: "#585858", button: "#444444", buttonText: "#eeeeee", status: "#444444", statusText: "#d0d0d0", statusBright: "#eeeeee",
        mode: "#d8e7dd", modeText: "#315c47", selection: "#d7e5df"
    )

    static let tokyoNight = Palette(
        isDark: true,
        background: "#1a1b26", foreground: "#c0caf5", border: "#292e42", primary: "#ff9e64", primaryForeground: "#1a1b26",
        muted: "#24283b", mutedForeground: "#7a82ad", sidebar: "#16161e", list: "#1a1b26", reader: "#1f2335", selected: "#283457",
        green: "#9ece6a", greenSoft: "#283322", orange: "#ff9e64", orangeSoft: "#3a2c27", purple: "#bb9af7", purpleSoft: "#2d2841",
        yellow: "#e0af68", yellowSoft: "#373124",
        aqua: "#7dcfff", aquaSoft: "#1f3346", blue: "#7aa2f7", blueSoft: "#222d4b", red: "#f7768e", redSoft: "#3a2431",
        body: "#a9b1d6", button: "#3b4261", buttonText: "#c0caf5", status: "#16161e", statusText: "#a9b1d6", statusBright: "#c0caf5",
        mode: "#283322", modeText: "#9ece6a", selection: "#33467c"
    )

    static let nord = Palette(
        isDark: true,
        background: "#2e3440", foreground: "#eceff4", border: "#434c5e", primary: "#d08770", primaryForeground: "#2e3440",
        muted: "#3b4252", mutedForeground: "#a0a8b7", sidebar: "#2a2f3a", list: "#2e3440", reader: "#323946", selected: "#394541",
        green: "#a3be8c", greenSoft: "#38443a", orange: "#d08770", orangeSoft: "#463a39", purple: "#b48ead", purpleSoft: "#403a4a",
        yellow: "#ebcb8b", yellowSoft: "#47443a",
        aqua: "#8fbcbb", aquaSoft: "#354547", blue: "#81a1c1", blueSoft: "#354155", red: "#bf616a", redSoft: "#47363d",
        body: "#d8dee9", button: "#434c5e", buttonText: "#eceff4", status: "#242933", statusText: "#d8dee9", statusBright: "#eceff4",
        mode: "#394541", modeText: "#a3be8c", selection: "#4c566a"
    )

    static let gruvboxLight = Palette(
        isDark: false,
        background: "#f2e5bc", foreground: "#3c3836", border: "#d5c4a1", primary: "#af3a03", primaryForeground: "#fbf1c7",
        muted: "#ebdbb2", mutedForeground: "#7c6f64", sidebar: "#efe2b9", list: "#f6ebc8", reader: "#fbf1c7", selected: "#e3dfb0",
        green: "#79740e", greenSoft: "#e6e2b5", orange: "#af3a03", orangeSoft: "#f2d8b8", purple: "#8f3f71", purpleSoft: "#ecd8d8",
        yellow: "#b57614", yellowSoft: "#f0dfb0",
        aqua: "#427b58", aquaSoft: "#dbe3c3", blue: "#076678", blueSoft: "#d6e1d6", red: "#9d0006", redSoft: "#f1d2bf",
        body: "#504945", button: "#3c3836", buttonText: "#fbf1c7", status: "#3c3836", statusText: "#d5c4a1", statusBright: "#fbf1c7",
        mode: "#e3dfb0", modeText: "#79740e", selection: "#d5c4a1"
    )

    static let solarizedLight = Palette(
        isDark: false,
        background: "#f5efdc", foreground: "#2f4a52", border: "#e3dcc6", primary: "#cb4b16", primaryForeground: "#fdf6e3",
        muted: "#eee8d5", mutedForeground: "#7f8f90", sidebar: "#eee8d5", list: "#f8f2e0", reader: "#fdf6e3", selected: "#e6ebd4",
        green: "#859900", greenSoft: "#ebeccf", orange: "#cb4b16", orangeSoft: "#f6dfcf", purple: "#6c71c4", purpleSoft: "#e8e3ee",
        yellow: "#b58900", yellowSoft: "#f3e7c4",
        aqua: "#2aa198", aquaSoft: "#dcece4", blue: "#268bd2", blueSoft: "#dce8ec", red: "#dc322f", redSoft: "#f6dcd2",
        body: "#586e75", button: "#073642", buttonText: "#fdf6e3", status: "#073642", statusText: "#93a1a1", statusBright: "#fdf6e3",
        mode: "#e6ebd4", modeText: "#5f7000", selection: "#e3dcc6"
    )

    static func of(_ id: ThemeID) -> Palette {
        switch id {
        case .gruvbox: .gruvbox
        case .tokyoNight: .tokyoNight
        case .nord: .nord
        case .papercolor: .papercolor
        case .gruvboxLight: .gruvboxLight
        case .solarizedLight: .solarizedLight
        }
    }

    /// Label colors in palette order: work green, personal orange, updates purple, reading yellow, ...
    var labelColors: [(fg: String, soft: String)] {
        [(green, greenSoft), (orange, orangeSoft), (purple, purpleSoft), (yellow, yellowSoft), (aqua, aquaSoft), (blue, blueSoft), (red, redSoft)]
    }

    /// CSS custom properties for the reader web view.
    var cssVariables: [String: String] {
        [
            "--background": background, "--foreground": foreground, "--border": border, "--primary": primary,
            "--muted": muted, "--muted-foreground": mutedForeground, "--reader": reader, "--selected": selected,
            "--green": green, "--green-soft": greenSoft, "--orange": orange, "--orange-soft": orangeSoft,
            "--purple": purple, "--purple-soft": purpleSoft, "--yellow": yellow, "--yellow-soft": yellowSoft,
            "--body": body, "--button": button, "--button-text": buttonText, "--selection": selection,
            "--status": status,
        ]
    }
}

extension Color {
    init(hex: String, opacity: Double = 1) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// SwiftUI colors for the active palette.
struct Theme: Equatable {
    let palette: Palette

    var background: Color { Color(hex: palette.background) }
    var foreground: Color { Color(hex: palette.foreground) }
    var border: Color { Color(hex: palette.border) }
    var primary: Color { Color(hex: palette.primary) }
    var muted: Color { Color(hex: palette.muted) }
    var mutedForeground: Color { Color(hex: palette.mutedForeground) }
    var sidebar: Color { Color(hex: palette.sidebar) }
    var list: Color { Color(hex: palette.list) }
    var reader: Color { Color(hex: palette.reader) }
    var selected: Color { Color(hex: palette.selected) }
    var green: Color { Color(hex: palette.green) }
    var greenSoft: Color { Color(hex: palette.greenSoft) }
    var orange: Color { Color(hex: palette.orange) }
    var orangeSoft: Color { Color(hex: palette.orangeSoft) }
    var purple: Color { Color(hex: palette.purple) }
    var purpleSoft: Color { Color(hex: palette.purpleSoft) }
    var yellow: Color { Color(hex: palette.yellow) }
    var yellowSoft: Color { Color(hex: palette.yellowSoft) }
    var red: Color { Color(hex: palette.red) }
    var body: Color { Color(hex: palette.body) }
    var button: Color { Color(hex: palette.button) }
    var buttonText: Color { Color(hex: palette.buttonText) }
    var status: Color { Color(hex: palette.status) }
    var statusText: Color { Color(hex: palette.statusText) }
    var statusBright: Color { Color(hex: palette.statusBright) }
    var mode: Color { Color(hex: palette.mode) }
    var modeText: Color { Color(hex: palette.modeText) }
    var selection: Color { Color(hex: palette.selection) }

    func labelColor(_ index: Int) -> (fg: Color, soft: Color) {
        let pair = palette.labelColors[((index % palette.labelColors.count) + palette.labelColors.count) % palette.labelColors.count]
        return (Color(hex: pair.fg), Color(hex: pair.soft))
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(palette: .gruvbox)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Fonts

enum AppFonts {
    /// Finds bundled resources: `Contents/Resources` in the .app, or the package's Resources folder
    /// when running from `swift run`.
    static let resourcesDirectory: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts"), FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.deletingLastPathComponent()
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Resources")
    }()

    static var fontFiles: [URL] {
        let directory = resourcesDirectory.appendingPathComponent("Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "ttf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func register() {
        for url in fontFiles {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// DM Sans at a size and weight. Falls back to the system font when the bundle has no fonts.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("DM Sans", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("IBM Plex Mono", size: size).weight(weight)
    }

    static func monoNSFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "IBMPlexMono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Base64 `@font-face` rules so the reader web view uses the same fonts.
    static let fontFaceCSS: String = {
        var rules: [String] = []
        for url in fontFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let family = name.hasPrefix("DMSans") ? "DM Sans" : "IBM Plex Mono"
            let weight: String = name.contains("Variable") ? "100 1000" : name.hasSuffix("SemiBold") ? "600" : name.hasSuffix("Medium") ? "500" : "400"
            rules.append("@font-face{font-family:'\(family)';font-weight:\(weight);font-style:normal;src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');}")
        }
        return rules.joined(separator: "\n")
    }()
}
