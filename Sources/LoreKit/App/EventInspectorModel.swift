import Foundation
import Observation

public enum EventDetailsLoad: Sendable, Equatable {
    case loading
    case loaded(CalendarEventDetails)
    /// No calendar access, or the occurrence is no longer in the calendar.
    case unavailable
}

/// The event that the main window inspector shows and how far its details have loaded.
public struct EventSelection: Sendable, Equatable {
    public var event: CalendarEventSnapshot
    public var load: EventDetailsLoad

    func isSameOccurrence(as other: CalendarEventSnapshot) -> Bool {
        event.id == other.id && event.startsAt == other.startsAt
    }
}

/// Holds the selected event and loads its details. Selecting another event shows `loading` at once, so the
/// details of the previous event never appear under the new one, and a late result for an earlier event is dropped.
@MainActor
@Observable
public final class EventInspectorModel {
    public private(set) var selection: EventSelection?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init() {}

    public func select(_ event: CalendarEventSnapshot, load: @escaping @Sendable (CalendarEventSnapshot) async -> CalendarEventDetails?) {
        if selection?.isSameOccurrence(as: event) == true { return }
        loadTask?.cancel()
        selection = EventSelection(event: event, load: .loading)
        loadTask = Task { [weak self] in
            let details = await load(event)
            guard !Task.isCancelled, let self, self.selection?.isSameOccurrence(as: event) == true else { return }
            self.selection?.load = details.map(EventDetailsLoad.loaded) ?? .unavailable
        }
    }

    public func clear() {
        loadTask?.cancel()
        loadTask = nil
        selection = nil
    }

    /// Keeps the selection only while its occurrence is on the day, and takes the day's fresh snapshot of it.
    public func reconcile(with events: [CalendarEventSnapshot]) {
        guard let current = selection else { return }
        guard let fresh = events.first(where: { current.isSameOccurrence(as: $0) }) else {
            clear()
            return
        }
        selection?.event = fresh
    }
}
