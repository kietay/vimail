import Foundation

/// The time, and a way to wait for it. The limiter and the budget take one so tests can move time by hand.
public protocol AIClock: Sendable {
    var now: Date { get }
    /// Returns at `deadline`, or at once when it has passed. Throws when the task is cancelled.
    func sleep(until deadline: Date) async throws
}

/// The system clock.
public struct WallClock: AIClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = deadline.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up)))) }
    }
}
