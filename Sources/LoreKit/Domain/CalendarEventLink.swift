import Foundation

/// Addresses that open one event in another app. Built on this Mac; nothing is fetched.
public enum CalendarEventLink {
    /// The Calendar app's address for an EventKit `eventIdentifier`.
    public static func calendarApp(eventID: String) -> URL? {
        guard !eventID.isEmpty,
              let encoded = eventID.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show")
    }

    /// The Google Calendar page of one occurrence, or nil unless `externalIdentifier` is `<id>@google.com`
    /// with a Google event id and `calendarEmail` is an email address.
    /// `occurrenceStart` is the original start of an occurrence of a repeating event, nil for a single event.
    public static func googleCalendar(externalIdentifier: String?, calendarEmail: String?, occurrenceStart: Date?,
                                      isAllDay: Bool, timeZone: TimeZone = .current) -> URL? {
        guard let externalIdentifier, let calendarEmail, isEmailAddress(calendarEmail) else { return nil }
        let suffix = "@google.com"
        guard externalIdentifier.hasSuffix(suffix) else { return nil }
        let baseID = externalIdentifier.dropLast(suffix.count)
        guard (5...1024).contains(baseID.count), baseID.allSatisfy(isGoogleEventIDCharacter) else { return nil }

        let eventID = occurrenceStart.map { "\(baseID)_\(instanceSuffix(for: $0, isAllDay: isAllDay, timeZone: timeZone))" } ?? String(baseID)
        let eid = Data("\(eventID) \(calendarEmail)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "https://calendar.google.com/calendar/event?eid=\(eid)")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Google event ids use base32hex: digits and the letters a to v.
    private static func isGoogleEventIDCharacter(_ character: Character) -> Bool {
        ("0"..."9").contains(character) || ("a"..."v").contains(character)
    }

    static func isEmailAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              text.allSatisfy({ !$0.isWhitespace && $0.isASCII }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    /// A timed occurrence is keyed by its original start in UTC, an all-day one by its date.
    private static func instanceSuffix(for start: Date, isAllDay: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = isAllDay ? timeZone : TimeZone(identifier: "UTC")
        formatter.dateFormat = isAllDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: start)
    }
}
