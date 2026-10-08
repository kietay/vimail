import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MailCore
import UniformTypeIdentifiers

/// Generates real, openable bytes for dummy attachments (text, calendar invites, PDFs, PNGs).
enum DummyAttachments {
    static func data(for attachment: MailAttachment, in message: MailMessage) -> Data {
        if attachment.id == "att-studio-next-chapter" {
            return Data("Studio North — The next chapter\n\nFewer projects. Deeper focus. More intention.\n\n1. Protect time for meaningful work.\n2. Choose fewer, better projects.\n3. Make room for experimentation.\n".utf8)
        }
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "ics": return calendar(for: message)
        case "pdf": return pdf(title: (attachment.filename as NSString).deletingPathExtension, subtitle: message.subject, body: message.plainText)
        case "png": return png(title: (attachment.filename as NSString).deletingPathExtension)
        default: return Data("\(attachment.filename)\n\nAttached to “\(message.subject)” from \(message.from.formatted).\n".utf8)
        }
    }

    private static func calendar(for message: MailMessage) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let start = message.date.addingTimeInterval(2 * 86_400)
        let title = message.subject.replacingOccurrences(of: "Invitation: ", with: "").components(separatedBy: " @ ").first ?? message.subject
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//vimail//dummy//EN
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:\(message.id)@vimail.dummy
        DTSTAMP:\(formatter.string(from: message.date))
        DTSTART:\(formatter.string(from: start))
        DTEND:\(formatter.string(from: start.addingTimeInterval(1800)))
        SUMMARY:\(title)
        ORGANIZER;CN=\(message.from.displayName):mailto:\(message.from.email)
        END:VEVENT
        END:VCALENDAR
        """
        return Data(ics.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    private static func pdf(title: String, subtitle: String, body: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        draw(title, size: 22, at: CGPoint(x: 56, y: 720), width: 500, in: context)
        draw(subtitle, size: 13, at: CGPoint(x: 56, y: 690), width: 500, in: context)
        draw(String(body.prefix(1_500)), size: 11, at: CGPoint(x: 56, y: 640), width: 500, height: 560, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, size: CGFloat, at origin: CGPoint, width: CGFloat, height: CGFloat = 40, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: origin.x, y: origin.y - height + size + 4, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func png(title: String) -> Data {
        let width = 960, height = 600
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        var hash: UInt64 = 1469598103934665603
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = CGFloat(hash % 360) / 360
        let colors = [hsb(hue, 0.35, 0.92), hsb(hue + 0.08, 0.5, 0.65)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        draw(title, size: 44, at: CGPoint(x: 60, y: 120), width: 840, height: 60, in: context)
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
        let h = hue.truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
