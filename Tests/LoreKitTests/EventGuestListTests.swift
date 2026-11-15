import Foundation
import Testing
@testable import LoreKit

@Suite("Event guests")
struct EventGuestListTests {
    static func attendee(_ name: String, _ status: CalendarParticipationStatus, kind: CalendarAttendeeKind = .person) -> CalendarAttendee {
        CalendarAttendee(name: name, status: status, kind: kind)
    }

    @Test("Rooms and resources are listed apart from people and are not counted")
    func splitsRooms() {
        let list = EventGuestList([
            Self.attendee("Mika", .accepted),
            Self.attendee("Room 4A", .accepted, kind: .room),
            Self.attendee("Projector", .pending, kind: .resource),
            Self.attendee("Design team", .pending, kind: .group),
            Self.attendee("Someone", .unknown, kind: .unknown),
        ])
        #expect(list.people.map(\.name) == ["Mika", "Design team", "Someone"])
        #expect(list.rooms.map(\.name) == ["Room 4A", "Projector"])
        #expect(list.counts.map(\.count).reduce(0, +) == 3)
    }

    @Test("Each status maps to one of four responses", arguments: [
        (CalendarParticipationStatus.accepted, AttendeeResponse.accepted),
        (.declined, .declined),
        (.tentative, .tentative),
        (.pending, .noResponse),
        (.unknown, .noResponse),
        (.none, .noResponse),
    ])
    func responseMapping(status: CalendarParticipationStatus, expected: AttendeeResponse) {
        #expect(AttendeeResponse(status) == expected)
    }

    @Test("Counts list only the responses that someone gave, in a fixed order")
    func counts() {
        let list = EventGuestList([
            Self.attendee("A", .pending), Self.attendee("B", .accepted), Self.attendee("C", .pending),
            Self.attendee("D", .accepted), Self.attendee("E", .tentative),
        ])
        #expect(list.counts.map { "\($0.response):\($0.count)" } == ["accepted:2", "tentative:1", "noResponse:2"])
    }

    @Test("No attendees")
    func empty() {
        let list = EventGuestList([])
        #expect(list.people.isEmpty && list.rooms.isEmpty && list.counts.isEmpty)
    }
}
