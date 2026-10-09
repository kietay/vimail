/// A cap on requests in flight where interactive requests get the next free slot before bulk ones.
///
/// `limit` can change at any time (a pacer lowers it when rate limited). `bulkLimit` keeps slots free
/// for interactive work: bulk requests never hold more than that many at once.
public actor PrioritySlots {
    public enum Priority: Sendable { case bulk, interactive }

    public private(set) var limit: Int
    public private(set) var bulkLimit: Int
    public private(set) var inFlight = 0
    private var bulkInFlight = 0
    private var interactiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var bulkWaiters: [CheckedContinuation<Void, Never>] = []

    /// Requests waiting for a slot.
    var waiting: Int { interactiveWaiters.count + bulkWaiters.count }

    /// - Parameter bulkLimit: at most this many bulk requests at once; nil means `limit`.
    public init(limit: Int, bulkLimit: Int? = nil) {
        self.limit = max(1, limit)
        self.bulkLimit = max(1, bulkLimit ?? limit)
    }

    /// Waits for a slot. Call `leave(priority:)` with the same priority when the request is done.
    public func enter(priority: Priority = .interactive) async {
        if canStart(priority) {
            take(priority)
            return
        }
        await withCheckedContinuation { continuation in
            if priority == .interactive { interactiveWaiters.append(continuation) } else { bulkWaiters.append(continuation) }
        }
    }

    public func leave(priority: Priority = .interactive) {
        inFlight -= 1
        if priority == .bulk { bulkInFlight -= 1 }
        fill()
    }

    /// Changes the caps. Raising them starts waiting requests right away.
    public func setLimit(_ limit: Int, bulkLimit: Int? = nil) {
        self.limit = max(1, limit)
        self.bulkLimit = max(1, bulkLimit ?? limit)
        fill()
    }

    private func canStart(_ priority: Priority) -> Bool {
        inFlight < limit && (priority == .interactive || bulkInFlight < bulkLimit)
    }

    private func take(_ priority: Priority) {
        inFlight += 1
        if priority == .bulk { bulkInFlight += 1 }
    }

    /// Fills free slots (more than one when a limit was just raised), interactive first.
    private func fill() {
        while !interactiveWaiters.isEmpty, canStart(.interactive) {
            take(.interactive)
            interactiveWaiters.removeFirst().resume()
        }
        while !bulkWaiters.isEmpty, canStart(.bulk) {
            take(.bulk)
            bulkWaiters.removeFirst().resume()
        }
    }
}
