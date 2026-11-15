import Foundation
import Testing
@testable import LoreKit

/// A loader that finishes only when the test says so, to control the order of results.
private actor GatedLoader {
    private var waiting: [String: CheckedContinuation<CalendarEventDetails?, Never>] = [:]
    private(set) var requested: [String] = []

    func load(_ event: CalendarEventSnapshot) async -> CalendarEventDetails? {
        requested.append(event.title)
        return await withCheckedContinuation { waiting[event.title] = $0 }
    }

    func finish(_ title: String, with details: CalendarEventDetails?) {
        waiting.removeValue(forKey: title)?.resume(returning: details)
    }

    func isWaiting(_ title: String) -> Bool { waiting[title] != nil }
}

@MainActor
@Suite("Event inspector")
struct EventInspectorTests {
    nonisolated static let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    nonisolated static func event(_ title: String, id: String? = nil, at start: Date = noon) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id ?? title, title: title, startsAt: start, endsAt: start.addingTimeInterval(1800), calendarTitle: "Work")
    }

    nonisolated static func details(for event: CalendarEventSnapshot, notes: String) -> CalendarEventDetails {
        CalendarEventDetails(eventID: event.id, startsAt: event.startsAt, notes: notes)
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Selecting an event shows it as loading, then loaded")
    func loadsDetails() async {
        let model = EventInspectorModel()
        let loader = GatedLoader()
        let standup = Self.event("Standup")
        model.select(standup) { await loader.load($0) }
        #expect(model.selection == EventSelection(event: standup, load: .loading))
        await waitUntil { await loader.isWaiting("Standup") }
        let details = Self.details(for: standup, notes: "agenda")
        await loader.finish("Standup", with: details)
        await waitUntil { model.selection?.load != .loading }
        #expect(model.selection == EventSelection(event: standup, load: .loaded(details)))
    }

    @Test("A reader that returns nothing leaves the event unavailable with its snapshot")
    func unavailable() async {
        let model = EventInspectorModel()
        let standup = Self.event("Standup")
        model.select(standup) { _ in nil }
        await waitUntil { model.selection?.load != .loading }
        #expect(model.selection == EventSelection(event: standup, load: .unavailable))
    }

    @Test("Selecting another event shows loading at once and drops the late result of the first")
    func lateResultIsDropped() async {
        let model = EventInspectorModel()
        let loader = GatedLoader()
        let first = Self.event("First")
        let second = Self.event("Second")
        model.select(first) { await loader.load($0) }
        await waitUntil { await loader.isWaiting("First") }
        model.select(second) { await loader.load($0) }
        #expect(model.selection == EventSelection(event: second, load: .loading))
        await waitUntil { await loader.isWaiting("Second") }

        await loader.finish("First", with: Self.details(for: first, notes: "first notes"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selection == EventSelection(event: second, load: .loading))

        let secondDetails = Self.details(for: second, notes: "second notes")
        await loader.finish("Second", with: secondDetails)
        await waitUntil { model.selection?.load != .loading }
        #expect(model.selection == EventSelection(event: second, load: .loaded(secondDetails)))
    }

    @Test("A loaded event is replaced by loading, never by the old details under the new event")
    func switchingNeverShowsOldDetails() async {
        let model = EventInspectorModel()
        let first = Self.event("First")
        let second = Self.event("Second")
        model.select(first) { Self.details(for: $0, notes: "first notes") }
        await waitUntil { model.selection?.load != .loading }
        let loader = GatedLoader()
        model.select(second) { await loader.load($0) }
        #expect(model.selection?.event == second)
        #expect(model.selection?.load == .loading)
    }

    @Test("Selecting the occurrence that is already selected does not load again")
    func sameOccurrenceIsIgnored() async {
        let model = EventInspectorModel()
        let loader = GatedLoader()
        let standup = Self.event("Standup")
        model.select(standup) { await loader.load($0) }
        await waitUntil { await loader.isWaiting("Standup") }
        model.select(standup) { await loader.load($0) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await loader.requested == ["Standup"])
    }

    @Test("Two occurrences of a repeating event are different selections")
    func occurrencesAreDistinct() async {
        let model = EventInspectorModel()
        let monday = Self.event("Weekly", id: "weekly", at: Self.noon)
        let nextMonday = Self.event("Weekly", id: "weekly", at: Self.noon.addingTimeInterval(7 * 86_400))
        model.select(monday) { Self.details(for: $0, notes: "monday") }
        await waitUntil { model.selection?.load != .loading }
        model.select(nextMonday) { Self.details(for: $0, notes: "next") }
        #expect(model.selection == EventSelection(event: nextMonday, load: .loading))
        await waitUntil { model.selection?.load != .loading }
        #expect(model.selection?.load == .loaded(Self.details(for: nextMonday, notes: "next")))
    }

    @Test("Clearing drops the selection and a pending result")
    func clearDropsPendingResult() async {
        let model = EventInspectorModel()
        let loader = GatedLoader()
        let standup = Self.event("Standup")
        model.select(standup) { await loader.load($0) }
        await waitUntil { await loader.isWaiting("Standup") }
        model.clear()
        await loader.finish("Standup", with: Self.details(for: standup, notes: "x"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selection == nil)
    }

    @Test("Reconcile keeps the selection while the occurrence is on the day and takes the fresh snapshot")
    func reconcileKeeps() async {
        let model = EventInspectorModel()
        let standup = Self.event("Standup")
        model.select(standup) { Self.details(for: $0, notes: "x") }
        await waitUntil { model.selection?.load != .loading }
        var renamed = standup
        renamed.title = "Standup (moved room)"
        model.reconcile(with: [Self.event("Other"), renamed])
        #expect(model.selection?.event.title == "Standup (moved room)")
        #expect(model.selection?.load == .loaded(Self.details(for: standup, notes: "x")))
    }

    @Test("Reconcile clears the selection when the occurrence is no longer on the day")
    func reconcileClears() async {
        let model = EventInspectorModel()
        let standup = Self.event("Standup")
        model.select(standup) { Self.details(for: $0, notes: "x") }
        await waitUntil { model.selection?.load != .loading }
        model.reconcile(with: [Self.event("Standup", at: Self.noon.addingTimeInterval(86_400))])
        #expect(model.selection == nil)
    }
}
