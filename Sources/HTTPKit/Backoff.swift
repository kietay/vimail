import Foundation

/// How long to wait before retrying: exponential with jitter, capped, and never sooner than the server asked.
///
/// Attempt n waits `first × factor^(n-1)`, at most `maximum`, then ±`jitter` (a fraction) so many
/// clients that failed together do not retry together. A server's retry-after replaces the
/// exponential part (still capped) and jitter only adds to it.
public struct Backoff: Sendable, Hashable {
    public var first: Duration
    public var factor: Double
    public var maximum: Duration
    public var jitter: Double

    public init(first: Duration, factor: Double = 2, maximum: Duration, jitter: Double = 0.2) {
        self.first = first
        self.factor = factor
        self.maximum = maximum
        self.jitter = min(max(jitter, 0), 1)
    }

    /// The wait before attempt `attempt + 1`, after `attempt` failures (1 or more).
    public func delay(afterAttempt attempt: Int, retryAfter: Duration? = nil) -> Duration {
        var generator = SystemRandomNumberGenerator()
        return delay(afterAttempt: attempt, retryAfter: retryAfter, using: &generator)
    }

    public func delay(afterAttempt attempt: Int, retryAfter: Duration? = nil, using generator: inout some RandomNumberGenerator) -> Duration {
        if let retryAfter {
            let base = min(max(retryAfter, .zero), maximum)
            return base + base * Double.random(in: 0...jitter, using: &generator)
        }
        let exponent = Double(max(attempt, 1) - 1)
        // Compare in seconds first: `factor^exponent` overflows Duration long before it overflows Double.
        let seconds = Self.seconds(first) * pow(factor, exponent)
        let base = seconds >= Self.seconds(maximum) ? maximum : first * pow(factor, exponent)
        return base + base * Double.random(in: -jitter...jitter, using: &generator)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
