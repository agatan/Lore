import Foundation

/// Details of one event occurrence, read from the calendar on demand and never persisted.
/// `eventID` and `startsAt` match `CalendarEventSnapshot.id` and `startsAt` of the same occurrence.
public struct CalendarEventDetails: Sendable, Hashable {
    public let eventID: String
    public let startsAt: Date
    /// `calendarItemExternalIdentifier`, the identifier that the calendar server gives the event.
    public let externalIdentifier: String?
    public let notes: String?
    public let location: String?
    public let url: URL?
    public let organizer: CalendarAttendee?
    public let attendees: [CalendarAttendee]
    public let isCanceled: Bool
    public let conferenceLink: ConferenceLink?

    public init(eventID: String, startsAt: Date, externalIdentifier: String? = nil, notes: String? = nil,
                location: String? = nil, url: URL? = nil, organizer: CalendarAttendee? = nil,
                attendees: [CalendarAttendee] = [], isCanceled: Bool = false) {
        self.eventID = eventID; self.startsAt = startsAt; self.externalIdentifier = externalIdentifier
        self.notes = notes; self.location = location; self.url = url
        self.organizer = organizer; self.attendees = attendees; self.isCanceled = isCanceled
        conferenceLink = ConferenceLink.first(url: url, location: location, notes: notes)
    }
}

extension Sequence where Element == CalendarEventDetails {
    /// Every occurrence of a repeating event shares `eventID`, so the start tells them apart.
    public func occurrence(eventID: String, startsAt: Date) -> CalendarEventDetails? {
        first { $0.eventID == eventID && $0.startsAt == startsAt }
    }
}

public struct CalendarAttendee: Sendable, Hashable {
    public var name: String?
    public var email: String?
    public var status: CalendarParticipationStatus
    public var role: CalendarAttendeeRole
    public var kind: CalendarAttendeeKind
    public var isCurrentUser: Bool

    public init(name: String? = nil, email: String? = nil, status: CalendarParticipationStatus = .unknown,
                role: CalendarAttendeeRole = .unknown, kind: CalendarAttendeeKind = .unknown, isCurrentUser: Bool = false) {
        self.name = name; self.email = email; self.status = status
        self.role = role; self.kind = kind; self.isCurrentUser = isCurrentUser
    }

    /// The address of a `mailto:` participant URL. Other schemes, such as `urn:uuid:`, carry no address.
    public static func email(fromParticipantURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        let decoded = String(address).removingPercentEncoding ?? String(address)
        return decoded.isEmpty ? nil : decoded
    }
}

public enum CalendarAttendeeRole: String, Sendable, Hashable {
    case required, optional, chair, nonParticipant, unknown
}

public enum CalendarAttendeeKind: String, Sendable, Hashable {
    case person, room, resource, group, unknown
}

public enum ConferenceProvider: String, Sendable, Hashable, CaseIterable {
    case googleMeet, zoom, microsoftTeams, webex
}

public struct ConferenceLink: Sendable, Hashable {
    public var provider: ConferenceProvider
    public var url: URL

    public init(provider: ConferenceProvider, url: URL) {
        self.provider = provider
        self.url = url
    }

    /// The fields are searched in the order URL, location, notes. Within a field the first meeting link wins.
    public static func first(url: URL?, location: String?, notes: String?) -> ConferenceLink? {
        for text in [url?.absoluteString, location, notes].compactMap(\.self) {
            if let link = links(in: text).first { return link }
        }
        return nil
    }

    private static func links(in text: String) -> [ConferenceLink] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            match.url.flatMap(meetingLink)
        }
    }

    private static func meetingLink(_ url: URL) -> ConferenceLink? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              let provider = provider(host: host, path: components.path) else { return nil }
        components.scheme = "https"
        return components.url.map { ConferenceLink(provider: provider, url: $0) }
    }

    private static func provider(host: String, path: String) -> ConferenceProvider? {
        let segments = path.split(separator: "/").map { $0.lowercased() }
        guard let firstSegment = segments.first else { return nil }
        func isUnder(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host == "meet.google.com" { return .googleMeet }
        if isUnder("zoom.us") || isUnder("zoomgov.com") {
            return ["j", "my", "w"].contains(firstSegment) && segments.count > 1 ? .zoom : nil
        }
        if host == "teams.microsoft.com" {
            return path.lowercased().hasPrefix("/l/meetup-join/") || firstSegment == "meet" ? .microsoftTeams : nil
        }
        if host == "teams.live.com" { return firstSegment == "meet" ? .microsoftTeams : nil }
        if isUnder("webex.com") {
            return segments.last == "j.php" || ["meet", "join"].contains(firstSegment) ? .webex : nil
        }
        return nil
    }
}
