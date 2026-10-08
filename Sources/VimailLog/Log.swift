import Foundation
import os

/// vimail's log. Each line goes to the unified log (Console.app, subsystem `dev.vimail`) and, once the
/// app has started the file, to `~/Library/Logs/vimail/vimail.log` (rotated at 5 MB, three files kept).
///
/// Privacy rule for every caller: log IDs, counts, sizes, timings, HTTP status codes and error text.
/// Never log message content, subjects, other people's addresses, OAuth codes or tokens.
public struct Log: Sendable {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, notice, error

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO "
            case .notice: "NOTE "
            case .error: "ERROR"
            }
        }

        var osType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .error: .error
            }
        }
    }

    public let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "dev.vimail", category: category)
    }

    public func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
    public func info(_ message: @autoclosure () -> String) { write(.info, message) }
    public func notice(_ message: @autoclosure () -> String) { write(.notice, message) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message) }

    private func write(_ level: Level, _ message: () -> String) {
        let text = message()
        logger.log(level: level.osType, "\(text, privacy: .public)")
        LogFile.shared.append(level: level, category: category, text)
    }
}

/// The plain-text log file. Lines are written in order on a background queue.
public final class LogFile: @unchecked Sendable {
    public static let shared = LogFile()

    private let queue = DispatchQueue(label: "dev.vimail.log-file")
    private var handle: FileHandle?
    private var directory: URL?
    private var size: UInt64 = 0
    private let maxSize: UInt64 = 5_000_000
    private let keptFiles = 3
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts writing to `directory/vimail.log`. Before this, lines only reach the unified log.
    public func start(directory: URL) {
        queue.sync {
            self.directory = directory
            openFile()
        }
    }

    /// The current log file, once started.
    public var url: URL? {
        queue.sync { directory?.appendingPathComponent("vimail.log") }
    }

    func append(level: Log.Level, category: String, _ text: String) {
        let date = Date()
        queue.async { [self] in
            guard let handle else { return }
            let data = Data("\(formatter.string(from: date)) \(level.label) [\(category)] \(text)\n".utf8)
            handle.write(data)
            size += UInt64(data.count)
            if size > maxSize { rotate() }
        }
    }

    private func openFile() {
        guard let directory else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vimail.log")
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// vimail.log → vimail.1.log → vimail.2.log; the oldest is dropped.
    private func rotate() {
        guard let directory else { return }
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        let name = { (index: Int) in directory.appendingPathComponent(index == 0 ? "vimail.log" : "vimail.\(index).log") }
        try? manager.removeItem(at: name(keptFiles - 1))
        for index in stride(from: keptFiles - 2, through: 0, by: -1) {
            try? manager.moveItem(at: name(index), to: name(index + 1))
        }
        openFile()
    }
}

/// Elapsed time for log lines.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now

    public init() {}

    public var milliseconds: Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// "850ms" or "12.4s".
    public var text: String {
        let ms = milliseconds
        return ms < 10_000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }
}
