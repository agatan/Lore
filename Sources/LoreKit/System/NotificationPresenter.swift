import Foundation
import UserNotifications

/// Posts "notes are ready" and "digest is ready", and reports a click back with the event occurrence or the day.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let eventIDKey = "eventID"
    private nonisolated static let dayKey = "day"

    var onOpenEvent: ((EventOccurrence) -> Void)?
    var onOpenDay: ((String) -> Void)?

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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
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
