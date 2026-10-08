// Renders Resources/AppIcon.icns: the "vi/_" mark on a full-bleed Gruvbox background.
// macOS applies its own squircle mask to full-canvas icons.
// Usage: swift scripts/make-icon.swift   (from the vimail directory)
import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fontURL = root.appendingPathComponent("Resources/Fonts/IBMPlexMono-Medium.ttf")
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor], let descriptor = descriptors.first else {
    fatalError("Missing \(fontURL.path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's icon shape: a continuous-corner squircle (superellipse approximation).
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5.2
    let a = rect.width / 2, b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = a * copysign(pow(abs(cosT), 2 / n), cosT)
        let y = b * copysign(pow(abs(sinT), 2 / n), sinT)
        let point = CGPoint(x: center.x + x, y: center.y + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func render(size: Int) -> CGImage {
    let scale = CGFloat(size) / 1024
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Full bleed: macOS 26 masks full-canvas legacy icons into its own squircle. Icons with
    // transparent margins get shrunk onto a grey platter instead.
    let body = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let shape = CGPath(rect: body, transform: nil)

    // Background: Gruvbox gradient with the app's soft green and orange glows.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let base = CGGradient(colorsSpace: space, colors: [color(0x32302f), color(0x1d2021)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    let green = CGGradient(colorsSpace: space, colors: [color(0x34392e, 0.95), color(0x34392e, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(green, startCenter: CGPoint(x: 80, y: 960), startRadius: 0, endCenter: CGPoint(x: 80, y: 960), endRadius: 780, options: [])
    let orange = CGGradient(colorsSpace: space, colors: [color(0x443427, 0.9), color(0x443427, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(orange, startCenter: CGPoint(x: 960, y: 60), startRadius: 0, endCenter: CGPoint(x: 960, y: 60), endRadius: 760, options: [])
    context.restoreGState()

    // The mark: "vi" in cream, "/_" in Gruvbox orange.
    let font = CTFontCreateWithFontDescriptor(descriptor, 360, nil)
    let mark = NSMutableAttributedString(string: "vi/_", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0xebdbb2),
        NSAttributedString.Key(kCTKernAttributeName as String): -17,
    ])
    mark.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color(0xfe8019), range: NSRange(location: 2, length: 2))
    let line = CTLineCreateWithAttributedString(mark)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let x = 512 - bounds.width / 2 - bounds.minX
    let y = 512 - bounds.height / 2 - bounds.minY + 8
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)

    return context.makeImage()!
}

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for factor in scales {
        let image = render(size: points * factor)
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let preview = NSBitmapImageRep(cgImage: render(size: 1024))
try preview.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/AppIcon-1024.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
