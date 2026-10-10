import Foundation
import Testing
@testable import MailAI
import MailCore

@Suite("Spend guard")
struct SpendGuardTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Local time in Los Angeles.
    static func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func makeGuard(_ budget: SpendGuard.Budget = .standard, at date: Date = local(10, 9, 12), file: URL? = nil, projection: Int64? = nil) -> (SpendGuard, TestClock) {
        let clock = TestClock(date)
        return (SpendGuard(file: file, budget: budget, liveProjection: projection, calendar: Self.calendar, clock: clock), clock)
    }

    func spend(_ guard: SpendGuard, _ lane: SpendLane, _ micros: Int64) async throws {
        let reservation = try await `guard`.reserve(lane: lane, worstCase: micros, inputEstimate: 0)
        await `guard`.settle(reservation, actualMicros: micros)
    }

    @Test func concurrentReservationsNeverExceedACap() async {
        let (spend, _) = makeGuard()
        let granted = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    if (try? await spend.reserve(lane: .live, worstCase: 70_000, inputEstimate: 10_000)) != nil { granted.increment() }
                }
            }
        }
        // $3.00 / $0.07 = 42 whole reservations, leaving $0.06.
        #expect(granted.count == 42)
        await #expect(throws: JudgeError.paused(.budgetDay)) { try await spend.reserve(lane: .live, worstCase: 60_001, inputEstimate: 0) }
    }

    @Test func settlingFreesWhatACallDidNotUse() async throws {
        let (spend, _) = makeGuard()
        let first = try await spend.reserve(lane: .live, worstCase: 2_000_000, inputEstimate: 50_000)
        await #expect(throws: JudgeError.paused(.budgetDay)) { try await spend.reserve(lane: .live, worstCase: 1_500_000, inputEstimate: 0) }
        await spend.settle(first, actualMicros: 400)
        _ = try await spend.reserve(lane: .live, worstCase: 1_500_000, inputEstimate: 0)
        // Settling twice changes nothing.
        await spend.settle(first, actualMicros: 400)
        #expect(await spend.snapshot().spendToday == 400)
    }

    @Test func cancelSettlesTheInputEstimate() async throws {
        let (spend, _) = makeGuard()
        await spend.cancel(try await spend.reserve(lane: .run(4), worstCase: 9_000, inputEstimate: 1_200))
        #expect(await spend.snapshot().spendToday == 1_200)
    }

    @Test func liveMayUseTheWholeDayButRunsLeaveTheReserve() async throws {
        let (spend, clock) = makeGuard()
        // A week of live mail at $0.50 a day: runs leave $1.00 today.
        for daysAgo in 1...7 {
            clock.advance(by: -86_400 * Double(daysAgo))
            try await self.spend(spend, .live, 500_000)
            clock.advance(by: 86_400 * Double(daysAgo))
        }
        #expect(await spend.snapshot().liveDailyAverage == 500_000)
        try await self.spend(spend, .run(1), 1_500_000)
        #expect(await spend.snapshot().runRoomToday == 500_000)
        await #expect(throws: JudgeError.budget(.runRoom)) { try await spend.reserve(lane: .run(1), worstCase: 600_000, inputEstimate: 0) }
        _ = try await spend.reserve(lane: .run(1), worstCase: 500_000, inputEstimate: 0)
        // Live mail still has its reserve, and may go right up to the cap.
        _ = try await spend.reserve(lane: .live, worstCase: 1_000_000, inputEstimate: 0)
        await #expect(throws: JudgeError.paused(.budgetDay)) { try await spend.reserve(lane: .live, worstCase: 1, inputEstimate: 0) }
        await #expect(throws: JudgeError.budget(.day)) { try await spend.reserve(lane: .run(2), worstCase: 1, inputEstimate: 0) }
    }

    @Test func runsLeaveTheMonthsReserve() async throws {
        // 9 October: 23 days left counting today. At $0.50 a day live mail keeps $11.50 of the month.
        let (spend, _) = makeGuard(SpendGuard.Budget(day: 20_000_000, month: 20_000_000, previewDay: 750_000), projection: 500_000)
        try await self.spend(spend, .run(1), 8_000_000)
        #expect(await spend.snapshot().runRoomToday == 500_000)
        await #expect(throws: JudgeError.budget(.runRoom)) { try await spend.reserve(lane: .run(1), worstCase: 500_001, inputEstimate: 0) }
        _ = try await spend.reserve(lane: .live, worstCase: 12_000_000, inputEstimate: 0)
        await #expect(throws: JudgeError.paused(.budgetMonth)) { try await spend.reserve(lane: .live, worstCase: 1, inputEstimate: 0) }
    }

    @Test func previewsStopAtTheirAllowanceAndKeepTheReserve() async throws {
        let (spend, _) = makeGuard(projection: 400_000)
        try await self.spend(spend, .preview, 700_000)
        #expect(await spend.snapshot().previewLeft == 50_000)
        await #expect(throws: JudgeError.budget(.previewRoom)) { try await spend.reserve(lane: .preview, worstCase: 60_000, inputEstimate: 0) }
        _ = try await spend.reserve(lane: .preview, worstCase: 50_000, inputEstimate: 0)
        // A run spends most of the day: previews then also stop at live mail's reserve ($0.80).
        let (busy, _) = makeGuard(projection: 400_000)
        try await self.spend(busy, .run(1), 2_100_000)
        #expect(await busy.snapshot().previewLeft == 100_000)
        await #expect(throws: JudgeError.budget(.previewRoom)) { try await busy.reserve(lane: .preview, worstCase: 100_001, inputEstimate: 0) }
    }

    @Test func theProjectionStandsInUntilLiveSpendExists() async throws {
        let (spend, clock) = makeGuard(projection: 300_000)
        #expect(await spend.snapshot().liveDailyAverage == 300_000)
        // Today's live spend doesn't count yet: the day isn't over.
        try await self.spend(spend, .live, 100_000)
        #expect(await spend.snapshot().liveDailyAverage == 300_000)
        // Two days of history: their mean, not a seven-day one.
        clock.advance(by: 86_400)
        try await self.spend(spend, .live, 200_000)
        clock.advance(by: 86_400)
        #expect(await spend.snapshot().liveDailyAverage == 150_000)
    }

    @Test func daysResetAtLocalMidnight() async throws {
        let (spend, clock) = makeGuard(at: Self.local(10, 9, 23, 50))
        try await self.spend(spend, .live, 2_900_000)
        await #expect(throws: JudgeError.paused(.budgetDay)) { try await spend.reserve(lane: .live, worstCase: 200_000, inputEstimate: 0) }
        clock.advance(by: 20 * 60)
        _ = try await spend.reserve(lane: .live, worstCase: 200_000, inputEstimate: 0)
        let snapshot = await spend.snapshot()
        #expect(snapshot.spendToday == 0 && snapshot.spendMonth == 2_900_000)

        // A new month starts from zero too.
        let (monthly, later) = makeGuard(SpendGuard.Budget(day: 5_000_000, month: 5_000_000, previewDay: 0), at: Self.local(10, 31, 23, 0))
        try await self.spend(monthly, .live, 4_900_000)
        later.advance(by: 2 * 3600)
        #expect(await monthly.snapshot().spendMonth == 0)
    }

    @Test func spendAndTheFallbackFlagPersistInAPrivateFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ai-usage.json")
        let (first, _) = makeGuard(file: file)
        try await spend(first, .live, 120_000)
        try await spend(first, .run(3), 300_000)
        try await spend(first, .preview, 5_000)
        await first.setFallbacksUnavailable()

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let stored = try JSONDecoder().decode(SpendGuard.Ledger.self, from: Data(contentsOf: file))
        #expect(stored.days == ["2026-10-09": ["live": 120_000, "run": 300_000, "preview": 5_000]])
        #expect(stored.fallbacksUnavailable)

        let (second, _) = makeGuard(file: file)
        let snapshot = await second.snapshot()
        #expect(snapshot.spendToday == 425_000 && snapshot.fallbacksUnavailable)
        #expect(snapshot.previewLeft == 745_000)
    }

    @Test func daysOlderThanSixtyAreDropped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ai-usage.json")
        let (spend, clock) = makeGuard(at: Self.local(8, 1, 12), file: file)
        try await self.spend(spend, .live, 1_000)
        clock.advance(by: 86_400 * 61)
        try await self.spend(spend, .live, 2_000)
        let stored = try JSONDecoder().decode(SpendGuard.Ledger.self, from: Data(contentsOf: file))
        #expect(stored.days.keys.sorted() == ["2026-10-01"])
    }

    @Test func anUnreadableFileStartsFromZero() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai-usage.json")
        try Data("not json".utf8).write(to: file)
        let (spend, _) = makeGuard(file: file)
        #expect(await spend.snapshot().spendToday == 0)
    }

    @Test func snapshotShowsWhatRunsMayUseAndWhatStaysForLiveMail() async throws {
        // 9 October: 23 days left counting today. Live mail is projected at $0.50 a day.
        let (spend, _) = makeGuard(SpendGuard.Budget(day: 4_000_000, month: 35_000_000, previewDay: 1_000_000), projection: 500_000)
        try await self.spend(spend, .preview, 220_000)
        try await self.spend(spend, .live, 300_000)
        try await self.spend(spend, .run(1), 1_000_000)
        let snapshot = await spend.snapshot()
        #expect(snapshot.previewToday == 220_000)
        // Today $2.48 is left, $1.00 of it kept for live mail; the month keeps $11.50 of its $33.48.
        #expect(snapshot.liveReserveToday == 1_000_000)
        #expect(snapshot.runRoomToday == 1_480_000)
        #expect(snapshot.runRoomMonth == 21_980_000)

        // A reserve larger than what is left today keeps all of it.
        let (tight, _) = makeGuard(SpendGuard.Budget(day: 1_000_000, month: 35_000_000, previewDay: 250_000), projection: 600_000)
        let figures = await tight.snapshot()
        #expect(figures.liveReserveToday == 1_000_000 && figures.runRoomToday == 0 && figures.runRoomMonth == 35_000_000 - 600_000 * 23)
    }

    @Test func snapshotReportsTheBudgets() async {
        let (spend, _) = makeGuard(.debug)
        let snapshot = await spend.snapshot()
        #expect(snapshot.budgetDay == 1_000_000 && snapshot.budgetMonth == 5_000_000)
        #expect(snapshot.runRoomToday == 1_000_000 && snapshot.previewLeft == 250_000)
        #expect(SpendGuard.Budget.standard == SpendGuard.Budget(day: 3_000_000, month: 20_000_000, previewDay: 750_000))
    }
}
