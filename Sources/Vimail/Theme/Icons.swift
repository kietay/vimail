import SwiftUI

/// The design's line icons, drawn from the same SVG path data (24×24 viewBox, 1.5 stroke).
nonisolated enum IconName: String, CaseIterable {
    case inbox, send, file, archive, trash, star, search, plus, arrow, reply, chevron, chevronLeft, down
    case more, panel, command, settings, check, close, clock, link, pin, views, tag, folder, attach, spam, refresh, edit
}

struct Icon: View {
    let name: IconName
    var size: CGFloat = 18
    var filled = false

    var body: some View {
        ZStack {
            if filled {
                IconShape(name: name).fill(style: FillStyle(eoFill: false))
            }
            // The SVG viewBox is 24 wide with a 1.5 stroke; scale the stroke with the icon.
            IconShape(name: name).stroke(style: StrokeStyle(lineWidth: 1.5 * size / 24, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        // Stroked shapes only hit-test on the stroke; make the whole icon square clickable.
        .contentShape(Rectangle())
    }
}

nonisolated struct IconShape: Shape {
    let name: IconName

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for element in Self.elements(for: name) {
            switch element {
            case .path(let data): path.addPath(SVGPath.parse(data))
            case .circle(let cx, let cy, let r): path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case .rect(let x, let y, let w, let h, let r): path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            }
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }

    enum Element {
        case path(String)
        case circle(CGFloat, CGFloat, CGFloat)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }

    nonisolated static func elements(for name: IconName) -> [Element] {
        switch name {
        case .inbox: [.path("M4 4h16l2 10v6H2v-6L4 4Z"), .path("M2 14h6l2 3h4l2-3h6")]
        case .send: [.path("m3 3 18 9-18 9 3-9-3-9Z"), .path("M6 12h15")]
        case .file: [.path("M6 3h9l4 4v14H6Z"), .path("M14 3v5h5")]
        case .archive: [.path("M4 8h16v13H4Z M3 3h18v5H3Z M9 12h6")]
        case .trash: [.path("M3 6h18 M9 6V3h6v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7")]
        case .star: [.path("m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9Z")]
        case .search: [.circle(10.5, 10.5, 6.5), .path("m16 16 5 5")]
        case .plus: [.path("M12 5v14 M5 12h14")]
        case .arrow: [.path("M5 12h14 m-5-5 5 5-5 5")]
        case .reply: [.path("m9 5-6 6 6 6 M3 11h10c5 0 8 3 8 8")]
        case .chevron: [.path("m9 5 7 7-7 7")]
        case .chevronLeft: [.path("m15 5-7 7 7 7")]
        case .down: [.path("m5 9 7 7 7-7")]
        case .more: [.circle(5, 12, 1), .circle(12, 12, 1), .circle(19, 12, 1)]
        case .panel: [.rect(3, 4, 18, 16, 2), .path("M9 4v16")]
        case .command: [.path("M9 9H6a3 3 0 1 1 3-3v12a3 3 0 1 1-3-3h12a3 3 0 1 1-3 3V6a3 3 0 1 1 3 3H9Z")]
        case .settings: [.circle(12, 12, 3), .path("m9 3 6 0 1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1Z")]
        case .check: [.path("m5 12 4 4 10-10")]
        case .close: [.path("m6 6 12 12 M6 18 18 6")]
        case .clock: [.circle(12, 12, 9), .path("M12 7v5l3 2")]
        case .link: [.path("m9 15 6-6 M8 16l-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0 M16 8l1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0")]
        case .pin: [.path("m9 3 6 0-1 6 4 4H6l4-4-1-6 M12 13v8")]
        case .views: [.path("M3 5h18M6 12h12M9 19h6")]
        case .tag: [.path("M3 12V4h8l10 10-8 8L3 12Z"), .circle(7.5, 8, 1.2)]
        case .folder: [.path("M3 6h6l2 2h10v11H3Z")]
        case .attach: [.path("m20 11-8.5 8.5a5 5 0 0 1-7-7L13 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L14 7")]
        case .spam: [.path("M12 3 21 19H3Z M12 10v4 M12 17v.5")]
        case .refresh: [.path("M20 11a8 8 0 1 0-2 6 M20 5v6h-6")]
        case .edit: [.path("M4 20h4L19 9l-4-4L4 16Z M13 7l4 4")]
        }
    }
}

/// Minimal SVG path parser for the icon set: M L H V C S Q A Z, absolute and relative.
nonisolated enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var tokens = tokenize(data)[...]
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        func number() -> CGFloat? {
            guard let token = tokens.first, case .number(let value) = token else { return nil }
            tokens.removeFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while !tokens.isEmpty {
            if case .command(let next) = tokens.first! {
                command = next
                tokens.removeFirst()
            }
            let relative = command.isLowercase
            switch command.uppercased().first! {
            case "M":
                guard let p = point(relative: relative) else { tokens.removeFirst(); continue }
                path.move(to: p)
                current = p
                start = p
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let p = point(relative: relative) else { tokens.removeFirst(); continue }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H":
                guard let x = number() else { tokens.removeFirst(); continue }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = number() else { tokens.removeFirst(); continue }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = point(relative: relative), let c2 = point(relative: relative), let p = point(relative: relative) else { tokens.removeFirst(); continue }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case "S":
                guard let c2 = point(relative: relative), let p = point(relative: relative) else { tokens.removeFirst(); continue }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastControl = c2
            case "Q":
                guard let c = point(relative: relative), let p = point(relative: relative) else { tokens.removeFirst(); continue }
                path.addQuadCurve(to: p, control: c)
                current = p
                lastControl = c
            case "A":
                guard let rx = number(), let ry = number(), let _ = number(), let large = number(), let sweep = number(),
                      let p = point(relative: relative) else { tokens.removeFirst(); continue }
                addArc(to: &path, from: current, to: p, radius: (rx + ry) / 2, largeArc: large != 0, sweep: sweep != 0)
                current = p
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    /// Circular arc between two points (the icon set only uses circular arcs).
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, radius: CGFloat, largeArc: Bool, sweep: Bool) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let chord = sqrt(dx * dx + dy * dy)
        guard chord > 0 else { return }
        let r = max(radius, chord / 2)
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let h = sqrt(max(r * r - (chord / 2) * (chord / 2), 0))
        // Unit normal to the chord.
        let nx = -dy / chord, ny = dx / chord
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let center = CGPoint(x: mid.x + sign * h * nx, y: mid.y + sign * h * ny)
        let a0 = atan2(p0.y - center.y, p0.x - center.x)
        let a1 = atan2(p1.y - center.y, p1.x - center.x)
        // SVG sweep=1 is clockwise on screen (y down), which is "counter-clockwise" in Path's flipped terms.
        path.addArc(center: center, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: !sweep)
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty, let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for char in data {
            if char.isLetter && char != "e" {
                flush()
                tokens.append(.command(char))
            } else if char == "-" && !buffer.isEmpty && buffer.last != "e" {
                flush()
                buffer = "-"
            } else if char == "." && buffer.contains(".") {
                flush()
                buffer = "."
            } else if char == " " || char == "," {
                flush()
            } else {
                buffer.append(char)
            }
        }
        flush()
        return tokens
    }
}
