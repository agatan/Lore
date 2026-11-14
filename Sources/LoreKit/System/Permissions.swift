import AVFoundation
import AppKit
import ApplicationServices
import EventKit

/// マイクとアクセシビリティの権限状態。どちらも欠けると中核機能が動かないため、
/// UI から常に見える形にしておく。
@MainActor
public enum Permissions {
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public static var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// システムのアクセシビリティ許可ダイアログを出す。
    public static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt はグローバル var で並行安全でないため、キー名を直接使う。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openInputMonitoringSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    public static func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public static func openCalendarSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    public static var isCalendarGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 一度拒否したカレンダー権限はアプリから尋ね直せないため、システム設定を開く。
    public static var canPromptForCalendar: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    /// 未確認なら OS のダイアログを出す。拒否済みなら false を返すだけ(勝手に設定を開かない)。
    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
