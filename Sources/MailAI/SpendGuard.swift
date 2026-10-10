import Foundation
import HTTPKit
import MailCore
import VimailLog

/// Keeps Claude spend inside the budgets, for the whole app: one key pays for every account.
///
/// Every call reserves its worst case first (`reserve`) and settles what it cost after, so calls
/// running at once can never cross a cap together. Amounts are micro-dollars; days start at local
/// midnight.
///
/// **Lanes** (design §3.6):
/// - Live mail may use all of the day cap D and the month cap M.
/// - A run must leave live mail its reserve: 2 × the live daily average today, and the live average ×
///   the days left this month (today included).
/// - Previews and drafting keep the same reserve and also stop at the preview allowance P per day.
///
/// The live average is the mean daily live spend over the last 7 days before today (fewer when live
/// spend started more recently), or the projection made at consent until there is any.
///
/// **Errors:** live mail over a cap gets `.paused(.budgetDay)` or `.paused(.budgetMonth)`, because it
/// can't continue until midnight or the next month and the engine pauses the AI lane. Runs and
/// previews get `.budget(.day)` or `.budget(.month)` over a cap, and `.budget(.runRoom)` or
/// `.budget(.previewRoom)` when only their lane's room is spent; the engine pauses that run or stops
/// that preview, and live mail goes on.
///
/// Spend per day and lane (60 days) and the `fallbacksUnavailable` flag live in a mode-600 JSON file.
public actor SpendGuard {
    public struct Budget: Sendable, Hashable {
        public var day: Int64
        public var month: Int64
        /// The editor's daily allowance for previews and drafting.
        public var previewDay: Int64

        public init(day: Int64, month: Int64, previewDay: Int64) {
            self.day = day
            self.month = month
            self.previewDay = previewDay
        }

        /// $3 a day, $20 a month, previews $0.75 a day.
        public static let standard = Budget(day: 3_000_000, month: 20_000_000, previewDay: 750_000)
        /// Debug builds read real mail with real spend: $1 a day, $5 a month, previews a quarter of the day.
        public static let debug = Budget(day: 1_000_000, month: 5_000_000, previewDay: 250_000)
    }

    /// Money set aside for one call until it settles.
    public struct Reservation: Sendable, Hashable {
        let id: Int
        public let lane: SpendLane
        public let worstCase: Int64
        /// What the input alone would cost: settled when a call ends without an answer.
        public let inputEstimate: Int64
    }

    /// For the status bar and the rules manager.
    public struct Snapshot: Sendable, Hashable {
        public var spendToday: Int64
        public var spendMonth: Int64
        public var budgetDay: Int64
        public var budgetMonth: Int64
        /// What runs may still spend today, after live mail's reserve.
        public var runRoomToday: Int64
        /// What runs may still spend this month, after live mail's reserve for the days left.
        public var runRoomMonth: Int64
        /// What today's budget keeps for live mail: 2 × the live daily average, or what is left today.
        public var liveReserveToday: Int64
        /// What previews may still spend today.
        public var previewLeft: Int64
        /// What previews and drafting spent today.
        public var previewToday: Int64
        public var liveDailyAverage: Int64
        public var fallbacksUnavailable: Bool
    }

    /// What the file holds.
    struct Ledger: Codable, Equatable {
        /// "2026-10-09" → lane ("live", "run", "preview") → micro-dollars.
        var days: [String: [String: Int64]] = [:]
        /// Opus and Sonnet requests stopped sending `fallbacks` after the API rejected them.
        var fallbacksUnavailable = false

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            days = try container.decodeIfPresent([String: [String: Int64]].self, forKey: .days) ?? [:]
            fallbacksUnavailable = try container.decodeIfPresent(Bool.self, forKey: .fallbacksUnavailable) ?? false
        }
    }

    static let keptDays = 60

    private let file: URL?
    private var budget: Budget
    private var liveProjection: Int64?
    private let calendar: Calendar
    private let clock: any AIClock
    private var ledger: Ledger
    private var outstanding: [Int: Reservation] = [:]
    private var nextID = 0

    /// - Parameters:
    ///   - file: where spend is kept (`ai-usage.json`); nil keeps it in memory.
    ///   - liveProjection: daily live spend projected at consent, used until live spend exists.
    ///   - calendar: its time zone decides where days and months start.
    public init(file: URL?, budget: Budget, liveProjection: Int64? = nil, calendar: Calendar = .current, clock: any AIClock = WallClock()) {
        self.file = file
        self.budget = budget
        self.liveProjection = liveProjection
        self.calendar = calendar
        self.clock = clock
        ledger = Ledger()
        if let file, let data = PrivateFile.read(file) {
            do {
                ledger = try JSONDecoder().decode(Ledger.self, from: data)
            } catch {
                AnthropicClient.log.error("Unreadable Claude usage file (\(data.count) bytes): starting from zero")
            }
        }
    }

    public func setBudget(_ budget: Budget) {
        self.budget = budget
    }

    public func setLiveProjection(_ dailyMicros: Int64?) {
        liveProjection = dailyMicros
    }

    public var fallbacksUnavailable: Bool { ledger.fallbacksUnavailable }

    /// Remembers that the API rejects `fallbacks` for this key, across launches.
    public func setFallbacksUnavailable(_ unavailable: Bool = true) {
        guard ledger.fallbacksUnavailable != unavailable else { return }
        ledger.fallbacksUnavailable = unavailable
        save()
    }

    /// Sets aside `worstCase` for a call in `lane`, or throws when that would cross a budget.
    public func reserve(lane: SpendLane, worstCase: Int64, inputEstimate: Int64) throws(JudgeError) -> Reservation {
        let state = state()
        let dayLeft = budget.day - state.today
        let monthLeft = budget.month - state.month
        switch lane {
        case .live:
            if worstCase > monthLeft { throw .paused(.budgetMonth) }
            if worstCase > dayLeft { throw .paused(.budgetDay) }
        case .run, .preview:
            if worstCase > monthLeft { throw .budget(.month) }
            if worstCase > dayLeft { throw .budget(.day) }
            let room = min(dayLeft - state.dayReserve, monthLeft - state.monthReserve)
            let stop: BudgetStop = lane == .preview ? .previewRoom : .runRoom
            if worstCase > room { throw .budget(stop) }
            if lane == .preview, worstCase > budget.previewDay - state.previewToday { throw .budget(.previewRoom) }
        }
        nextID += 1
        let reservation = Reservation(id: nextID, lane: lane, worstCase: worstCase, inputEstimate: min(inputEstimate, worstCase))
        outstanding[reservation.id] = reservation
        return reservation
    }

    /// Records what a reserved call cost and frees the rest of its reservation.
    public func settle(_ reservation: Reservation, actualMicros: Int64) {
        guard outstanding.removeValue(forKey: reservation.id) != nil else { return }
        guard actualMicros > 0 else { return }
        let day = dayKey(clock.now)
        ledger.days[day, default: [:]][Self.laneKey(reservation.lane), default: 0] += actualMicros
        save()
    }

    /// Ends a call that may have been billed without an answer: settles its input estimate.
    public func cancel(_ reservation: Reservation) {
        settle(reservation, actualMicros: reservation.inputEstimate)
    }

    public func snapshot() -> Snapshot {
        let state = state()
        let dayLeft = budget.day - state.today
        let monthLeft = budget.month - state.month
        let runRoomMonth = max(0, monthLeft - state.monthReserve)
        let runRoom = max(0, min(dayLeft - state.dayReserve, runRoomMonth))
        return Snapshot(
            spendToday: state.settledToday, spendMonth: state.settledMonth, budgetDay: budget.day, budgetMonth: budget.month,
            runRoomToday: runRoom, runRoomMonth: runRoomMonth, liveReserveToday: max(0, min(state.dayReserve, dayLeft)),
            previewLeft: max(0, min(runRoom, budget.previewDay - state.previewToday)), previewToday: state.previewToday,
            liveDailyAverage: state.liveAverage, fallbacksUnavailable: ledger.fallbacksUnavailable
        )
    }

    // MARK: - Accounting

    /// Spend that counts against the caps now: settled plus reserved.
    private struct State {
        var settledToday: Int64 = 0
        var settledMonth: Int64 = 0
        var today: Int64 = 0
        var month: Int64 = 0
        var previewToday: Int64 = 0
        var liveAverage: Int64 = 0
        var dayReserve: Int64 = 0
        var monthReserve: Int64 = 0
    }

    private func state() -> State {
        let now = clock.now
        let today = dayKey(now)
        let month = String(today.prefix(7))
        var state = State()
        for (day, lanes) in ledger.days {
            let total = lanes.values.reduce(0, +)
            if day == today {
                state.settledToday += total
                state.previewToday += lanes[Self.laneKey(.preview)] ?? 0
            }
            if day.hasPrefix(month) { state.settledMonth += total }
        }
        let reserved = outstanding.values.reduce(Int64(0)) { $0 + $1.worstCase }
        state.today = state.settledToday + reserved
        state.month = state.settledMonth + reserved
        state.previewToday += outstanding.values.filter { $0.lane == .preview }.reduce(0) { $0 + $1.worstCase }
        state.liveAverage = liveAverage(now: now)
        state.dayReserve = 2 * state.liveAverage
        state.monthReserve = state.liveAverage * Int64(daysLeftInMonth(now))
        return state
    }

    private func liveAverage(now: Date) -> Int64 {
        let today = calendar.startOfDay(for: now)
        let todayKey = dayKey(today)
        let live = Self.laneKey(.live)
        // Keys sort by date. Today is left out: it is still filling up.
        guard let first = ledger.days.filter({ $0.key < todayKey && ($0.value[live] ?? 0) > 0 }).keys.min(),
              let firstDay = date(fromKey: first) else { return liveProjection ?? 0 }
        let days = min(7, max(1, calendar.dateComponents([.day], from: firstDay, to: today).day ?? 7))
        let total = (1...days).reduce(Int64(0)) { total, daysAgo in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today).map { dayKey($0) }
            return total + (day.flatMap { ledger.days[$0]?[live] } ?? 0)
        }
        return total / Int64(days)
    }

    /// Days from today to the end of the month, today included.
    private func daysLeftInMonth(_ now: Date) -> Int {
        guard let range = calendar.range(of: .day, in: .month, for: now) else { return 1 }
        return range.upperBound - calendar.component(.day, from: now)
    }

    /// "2026-10-09" in the calendar's time zone.
    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func laneKey(_ lane: SpendLane) -> String {
        switch lane {
        case .live: "live"
        case .run: "run"
        case .preview: "preview"
        }
    }

    private func save() {
        guard let file else { return }
        if let oldest = calendar.date(byAdding: .day, value: -Self.keptDays, to: calendar.startOfDay(for: clock.now)) {
            let cutoff = dayKey(oldest)
            ledger.days = ledger.days.filter { $0.key >= cutoff }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateFile.write(encoder.encode(ledger), to: file)
        } catch {
            AnthropicClient.log.error("Could not save Claude usage: \(String(describing: type(of: error))) \((error as NSError).code)")
        }
    }
}
