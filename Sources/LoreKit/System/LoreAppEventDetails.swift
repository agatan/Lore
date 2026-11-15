import EventKit
import Foundation

/// Reads the details of every event in a range, in one call. `lore-mcp` uses it to describe a day or period.
public protocol CalendarEventDetailsRangeReading: Sendable {
    /// Throws `EventDetailsUnavailable` when no details can be read at all.
    func details(start: Date, end: Date) async throws -> [CalendarEventDetails]
}

/// Why the event details of a request could not be read.
public enum EventDetailsUnavailable: LocalizedError, Sendable, Equatable {
    case loreNotRunning
    case noCalendarAccess
    case noAnswer(Int32)
    case invalidReply

    public var errorDescription: String? {
        let reason = switch self {
        case .loreNotRunning: "Loreが起動していないためです。Loreを起動すると、Loreがカレンダーから読み取って返します"
        case .noCalendarAccess: "Loreにカレンダーへのフルアクセスがないためです。システム設定の「プライバシーとセキュリティ」>「カレンダー」でLoreを許可してください"
        case .noAnswer(let code): "Loreが応答しませんでした(CFMessagePort \(code))"
        case .invalidReply: "Loreの応答を読めませんでした。lore-mcpとLoreの版が違う可能性があります"
        }
        return "予定の詳細(説明、主催者、参加者、参加リンク)は含まれていません。" + reason
    }
}

/// The request and reply on the port. Times are a range, so the caller names no event and no calendar.
struct EventDetailsRequest: Codable, Equatable {
    var start: Date
    var end: Date
}

enum EventDetailsReply: Codable, Equatable {
    case details([CalendarEventDetails])
    case noCalendarAccess
}

/// The `lore-mcp` side. macOS would attribute a calendar read in `lore-mcp` to the AI client that started it,
/// so it asks the running Lore app, which reads the calendar with the access the user gave Lore.
public struct LoreAppEventDetails: CalendarEventDetailsRangeReading {
    public static let portName = "dev.agatan.Lore.event-details"
    private let portName: String

    public init(portName: String = Self.portName) {
        self.portName = portName
    }

    public func details(start: Date, end: Date) async throws -> [CalendarEventDetails] {
        guard let port = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw EventDetailsUnavailable.loreNotRunning
        }
        defer { CFMessagePortInvalidate(port) }
        let request = try JSONEncoder().encode(EventDetailsRequest(start: start, end: end))
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 0, request as CFData, 1, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { throw EventDetailsUnavailable.noAnswer(status) }
        return try Self.details(fromReply: reply?.takeRetainedValue() as Data?)
    }

    static func details(fromReply data: Data?) throws -> [CalendarEventDetails] {
        guard let data, let reply = try? JSONDecoder().decode(EventDetailsReply.self, from: data) else {
            throw EventDetailsUnavailable.invalidReply
        }
        switch reply {
        case .details(let details): return details
        case .noCalendarAccess: throw EventDetailsUnavailable.noCalendarAccess
        }
    }
}

/// The app side. Answers on the main run loop while the app runs. It never asks for calendar access and keeps nothing.
@MainActor
public final class LoreAppEventDetailsServer {
    /// The details that start in a range, or nil without full calendar access.
    public typealias Read = @MainActor (Date, Date) -> [CalendarEventDetails]?
    private let read: Read
    private var port: CFMessagePort?

    /// Nil when another process already holds the port name.
    public init?(portName: String = LoreAppEventDetails.portName, read: @escaping Read) {
        self.read = read
        var context = CFMessagePortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFMessagePortCallBack = { _, _, data, info in
            let request = data as Data?
            let reply = MainActor.assumeIsolated {
                Unmanaged<LoreAppEventDetailsServer>.fromOpaque(info!).takeUnretainedValue().answer(request)
            }
            return reply.map { Unmanaged.passRetained($0 as CFData) }
        }
        guard let port = CFMessagePortCreateLocal(nil, portName as CFString, callback, &context, nil) else { return nil }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
    }

    isolated deinit {
        port.map(CFMessagePortInvalidate)
    }

    /// The app's answer: the calendars selected in the Life Log settings, read with the app's own access.
    public convenience init?(settings: AppSettings) {
        let store = EKEventStore()
        self.init { start, end in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
            return CalendarProvider.details(in: store, start: start, end: end, selectedCalendars: Set(settings.lifeLogCalendarTitles))
        }
    }

    private func answer(_ request: Data?) -> Data? {
        Self.reply(to: request, read: read)
    }

    /// `read` returns nil without full calendar access. A request that does not decode gets no reply.
    static func reply(to request: Data?, read: (Date, Date) -> [CalendarEventDetails]?) -> Data? {
        guard let request, let range = try? JSONDecoder().decode(EventDetailsRequest.self, from: request) else {
            LoreLog.automation.error("lore-mcpからの予定の詳細の要求を読めませんでした")
            return nil
        }
        do {
            return try JSONEncoder().encode(read(range.start, range.end).map(EventDetailsReply.details) ?? .noCalendarAccess)
        } catch {
            LoreLog.automation.error("予定の詳細の応答を作れませんでした: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
