import Foundation

public enum AttendeeResponse: Sendable, Hashable, CaseIterable {
    case accepted, declined, tentative, noResponse

    public init(_ status: CalendarParticipationStatus) {
        switch status {
        case .accepted: self = .accepted
        case .declined: self = .declined
        case .tentative: self = .tentative
        case .pending, .unknown, .none: self = .noResponse
        }
    }
}

/// The attendees of an event split into people and rooms. Rooms and resources are places, so they are not counted as guests.
public struct EventGuestList: Sendable, Equatable {
    public let people: [CalendarAttendee]
    public let rooms: [CalendarAttendee]

    public init(_ attendees: [CalendarAttendee]) {
        people = attendees.filter { $0.kind != .room && $0.kind != .resource }
        rooms = attendees.filter { $0.kind == .room || $0.kind == .resource }
    }

    public func count(of response: AttendeeResponse) -> Int {
        people.filter { AttendeeResponse($0.status) == response }.count
    }

    /// The responses that at least one guest gave, in a fixed order, with their counts.
    public var counts: [(response: AttendeeResponse, count: Int)] {
        AttendeeResponse.allCases.compactMap { response in
            let count = count(of: response)
            return count > 0 ? (response, count) : nil
        }
    }
}
