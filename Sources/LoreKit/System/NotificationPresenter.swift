import Foundation
import UserNotifications

/// Posts "notes are ready", "digest is ready", and the meeting reminder, and reports a click back with the event occurrence, the day, or the join link.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let eventIDKey = "eventID"
    private nonisolated static let dayKey = "day"
    private nonisolated static let joinURLKey = "joinURL"
    private nonisolated static let meetingCategory = "meeting-join"
    private nonisolated static let joinAction = "join"

    var onOpenEvent: ((EventOccurrence) -> Void)?
    var onOpenDay: ((String) -> Void)?
    var onJoinMeeting: ((URL) -> Void)?

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            LoreLog.session.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func postEventNotesReady(title: String, body: String, occurrence: EventOccurrence) async {
        await post(title: title, body: body, userInfo: [Self.eventIDKey: occurrence.eventID, Self.dayKey: occurrence.day],
                   identifier: "event-notes-\(occurrence.eventID)-\(occurrence.day)")
    }

    func postDailyDigestReady(title: String, body: String, day: String) async {
        await post(title: title, body: body, userInfo: [Self.dayKey: day], identifier: "daily-digest-\(day)")
    }

    private func post(title: String, body: String, userInfo: [String: String], identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch {
            LoreLog.session.error("Posting the notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The "Join" action title is set at each post, so it follows the display language.
    func postMeetingStartingSoon(_ meeting: JoinableMeeting, body: String, joinTitle: String) async {
        let center = UNUserNotificationCenter.current()
        let join = UNNotificationAction(identifier: Self.joinAction, title: joinTitle, options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [join], intentIdentifiers: []),
        ])
        let content = UNMutableNotificationContent()
        content.title = meeting.event.title
        content.body = body
        content.categoryIdentifier = Self.meetingCategory
        content.userInfo = [Self.joinURLKey: meeting.link.url.absoluteString]
        let request = UNNotificationRequest(identifier: "meeting-join-\(meeting.id)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            LoreLog.session.error("Posting the meeting notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let link = info[Self.joinURLKey] as? String, let url = URL(string: link) {
            guard [Self.joinAction, UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier) else { return }
            await MainActor.run { onJoinMeeting?(url) }
            return
        }
        guard let day = info[Self.dayKey] as? String else { return }
        if let eventID = info[Self.eventIDKey] as? String {
            await MainActor.run { onOpenEvent?(EventOccurrence(eventID: eventID, day: day)) }
        } else {
            await MainActor.run { onOpenDay?(day) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
