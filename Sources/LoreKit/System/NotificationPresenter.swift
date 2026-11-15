import Foundation
import UserNotifications

/// Posts "notes are ready" and reports a click back with the event occurrence.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let eventIDKey = "eventID"
    private nonisolated static let dayKey = "day"

    var onOpenEvent: ((EventOccurrence) -> Void)?

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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.eventIDKey: occurrence.eventID, Self.dayKey: occurrence.day]
        let request = UNNotificationRequest(identifier: "event-notes-\(occurrence.eventID)-\(occurrence.day)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            LoreLog.session.error("Posting the notes notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let eventID = info[Self.eventIDKey] as? String, let day = info[Self.dayKey] as? String else { return }
        await MainActor.run { onOpenEvent?(EventOccurrence(eventID: eventID, day: day)) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
