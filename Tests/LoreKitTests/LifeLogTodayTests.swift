import Foundation
import Testing
@testable import LoreKit

@Suite("The mini window's today stays on today")
@MainActor
struct LifeLogTodayTests {
    private func configured() async throws -> (LifeLogCoordinator, LoreDatabase) {
        let database = try await LoreDatabase.inMemory()
        let coordinator = LifeLogCoordinator()
        await coordinator.configure(
            database: database,
            engines: EngineRegistry(),
            vocabulary: { [] },
            participatingEventsOnly: { false },
            audioProcessingCompleted: {}
        )
        return (coordinator, database)
    }

    private var lastWeek: Date { Calendar.current.date(byAdding: .day, value: -7, to: Date())! }

    @Test("Selecting an earlier day, or jumping to it, leaves today on today")
    func selectingAnotherDayKeepsToday() async throws {
        let (coordinator, database) = try await configured()
        try await database.lifeLog.save(memo: LifeLogMemo(id: "past", createdAt: lastWeek, text: "last week"))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "now", createdAt: Date(), text: "today"))
        await coordinator.reload()
        #expect(coordinator.today.memos.map(\.id) == ["now"])

        await coordinator.select(date: lastWeek)
        #expect(coordinator.day.memos.map(\.id) == ["past"])
        #expect(coordinator.today.memos.map(\.id) == ["now"])

        await coordinator.showEvent(id: "any", day: LifeLogDateKey.string(for: lastWeek))
        #expect(coordinator.today.memos.map(\.id) == ["now"])
    }

    @Test("A memo added today appears in today while the main window shows an earlier day")
    func memoReachesTodayWhileBrowsing() async throws {
        let (coordinator, _) = try await configured()
        await coordinator.select(date: lastWeek)
        await coordinator.addMemo("from the mini window")
        #expect(coordinator.today.memos.map(\.text) == ["from the mini window"])
        #expect(coordinator.day.memos.isEmpty)
    }

    @Test("Events in progress come from today, not the selected day")
    func eventInProgressComesFromToday() async throws {
        let (coordinator, database) = try await configured()
        let now = Date()
        try await database.lifeLog.save(calendarEvents: [
            CalendarEventSnapshot(id: "sync", title: "Sync", startsAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(600), calendarTitle: "Work"),
        ])
        await coordinator.select(date: lastWeek)
        #expect(coordinator.day.calendarEvents.isEmpty)
        #expect(coordinator.today.calendarEvents.timedEventInProgress(at: now)?.id == "sync")
    }
}
