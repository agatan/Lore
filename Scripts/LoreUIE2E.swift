import AppKit
import ApplicationServices
import Foundation

private enum UIE2EError: LocalizedError {
    case accessibilityPermission
    case launch(String)
    case missing(String)
    case action(String)
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            "UI E2E runnerにアクセシビリティの許可がありません。実行元のターミナルをシステム設定で許可してください。"
        case .launch(let message), .action(let message), .assertion(let message): message
        case .missing(let description): "画面要素が見つかりません: \(description)"
        }
    }
}

private struct AXDriver {
    let application: AXUIElement

    init(pid: pid_t) {
        application = AXUIElementCreateApplication(pid)
    }

    func waitFor(identifier: String, timeout: TimeInterval = 8) throws -> AXUIElement {
        try waitFor("identifier=\(identifier)", timeout: timeout) {
            attribute(kAXIdentifierAttribute as String, of: $0) == identifier
        }
    }

    func exists(identifier: String) -> Bool {
        descendants().contains { attribute(kAXIdentifierAttribute as String, of: $0) == identifier }
    }

    func press(identifier: String) throws {
        let element = try waitFor(identifier: identifier)
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw UIE2EError.action("押せませんでした: \(identifier)")
        }
    }

    func pressMenuItem(title: String) throws {
        let item = try waitFor("menu item=\(title)", timeout: 8) { element in
            attribute(kAXRoleAttribute as String, of: element) == kAXMenuItemRole as String
                && attribute(kAXTitleAttribute as String, of: element) == title
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw UIE2EError.action("menuを押せませんでした: \(title)")
        }
    }

    func setValue(_ value: String, identifier: String) throws {
        let element = try waitFor(identifier: identifier)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFString
        ) == .success else {
            throw UIE2EError.action("入力できませんでした: \(identifier)")
        }
    }

    func waitFor(text: String, timeout: TimeInterval = 8) throws {
        _ = try waitFor("text=\(text)", timeout: timeout) { element in
            let title: String? = attribute(kAXTitleAttribute as String, of: element)
            let value: String? = attribute(kAXValueAttribute as String, of: element)
            return title == text || value == text
        }
    }

    /// The accessibility label, which SwiftUI reports as the description.
    func label(identifier: String) throws -> String? {
        let element = try waitFor(identifier: identifier)
        return attribute(kAXDescriptionAttribute as String, of: element)
    }

    /// A switch reports its state as a number.
    func isOn(identifier: String) throws -> Bool {
        let element = try waitFor(identifier: identifier)
        guard let value: NSNumber = attribute(kAXValueAttribute as String, of: element) else {
            throw UIE2EError.missing("value of \(identifier)")
        }
        return value.boolValue
    }

    func stringValue(identifier: String) throws -> String? {
        let element = try waitFor(identifier: identifier)
        return attribute(kAXValueAttribute as String, of: element)
    }

    func waitForString(identifier: String, timeout: TimeInterval = 8, matching predicate: (String) -> Bool) throws -> String {
        let element = try waitFor("identifier=\(identifier) with expected value", timeout: timeout) { element in
            guard attribute(kAXIdentifierAttribute as String, of: element) == identifier,
                  let value: String = attribute(kAXValueAttribute as String, of: element) else { return false }
            return predicate(value)
        }
        return attribute(kAXValueAttribute as String, of: element) ?? ""
    }

    func mainWindowSize() throws -> CGSize {
        guard let window = elements(kAXWindowsAttribute as String, of: application).first else {
            throw UIE2EError.missing("main window")
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            throw UIE2EError.missing("main window size")
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            throw UIE2EError.missing("main window size value")
        }
        return size
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval,
        predicate: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = descendants().first(where: predicate) { return match }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw UIE2EError.missing(description + "\n" + accessibilitySnapshot())
    }

    private func accessibilitySnapshot() -> String {
        descendants().compactMap { element in
            let role: String? = attribute(kAXRoleAttribute as String, of: element)
            let title: String? = attribute(kAXTitleAttribute as String, of: element)
            let identifier: String? = attribute(kAXIdentifierAttribute as String, of: element)
            let value: String? = attribute(kAXValueAttribute as String, of: element)
            let actionNames = actions(of: element)
            guard title != nil || identifier != nil || !actionNames.isEmpty else { return nil }
            return "role=\(role ?? "-") title=\(title ?? "-") id=\(identifier ?? "-") value=\(value ?? "-") actions=\(actionNames.joined(separator: ","))"
        }.prefix(120).joined(separator: "\n")
    }

    private func descendants() -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [application]
        var visited: Set<CFHashCode> = []
        while let element = pending.popLast(), result.count < 5_000 {
            guard visited.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            pending.append(contentsOf: elements(kAXChildrenAttribute as String, of: element).reversed())
        }
        return result
    }

    /// macOS 26ではCFArrayを`[AXUIElement]`へ直接castすると同じ要素へ化けるため、
    /// Core Foundationの配列から参照を1件ずつ取り出す。
    private func elements(_ name: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).map { index in
            Unmanaged<AXUIElement>
                .fromOpaque(CFArrayGetValueAtIndex(array, index)!)
                .takeUnretainedValue()
        }
    }

    private func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
}

@main
private enum LoreUIE2E {
    private static let uiTestBundleIdentifier = "dev.agatan.Lore.UIE2E"

    @MainActor
    static func main() async {
        do {
            let appURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/LoreUITests.app")
            guard Bundle(url: appURL)?.bundleIdentifier == uiTestBundleIdentifier else {
                throw UIE2EError.assertion(
                    "UI E2Eはテスト専用bundleでのみ実行できます: \(appURL.path)"
                )
            }
            guard AXIsProcessTrusted() else { throw UIE2EError.accessibilityPermission }
            try await runDailyReviewCUJ(appURL: appURL)
            try await runEmptyDayCUJ(appURL: appURL)
            try await runAISettingsCUJ(appURL: appURL)
            try await runOnboardingCUJ(appURL: appURL)
            try await runEventNotesCUJ(appURL: appURL)
            try await runDailyDigestCUJ(appURL: appURL)
            try await runMorningDigestCUJ(appURL: appURL)
            try await runJoinMeetingCUJ(appURL: appURL)
            terminateTestApp()
            print("✓ UI E2E: 8 CUJs passed")
        } catch {
            fputs("✗ UI E2E: \(error.localizedDescription)\n", stderr)
            terminateTestApp()
            exit(1)
        }
    }

    @MainActor
    private static func runDailyReviewCUJ(appURL: URL) async throws {
        print("CUJ 1: ライフログを検索して移動し、音声入力へ切り替え、日別書き出しを調整する")
        let app = try await launch(appURL, arguments: ["--lore-screenshot-demo"], activates: false)
        let ui = AXDriver(pid: app.processIdentifier)

        _ = try ui.waitFor(identifier: "main.section-picker")
        let activationDeadline = Date().addingTimeInterval(3)
        while !app.isActive, Date() < activationDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard app.isActive else {
            throw UIE2EError.assertion("通常起動したmain windowがactiveになっていません")
        }
        let mainWindowSize = try ui.mainWindowSize()
        guard mainWindowSize.width >= 1_680, mainWindowSize.height >= 960 else {
            throw UIE2EError.assertion(
                "main windowが既定の初期サイズではありません: \(mainWindowSize)"
            )
        }
        _ = try ui.waitFor(identifier: "life-log.voice-memo")
        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        guard !ui.exists(identifier: "life-log.timeline-divider") else {
            throw UIE2EError.assertion("単一timelineに廃止したcolumn dividerが残っています")
        }
        guard !ui.exists(identifier: "life-log.calendar-events") else {
            throw UIE2EError.assertion("inspectorへ移した予定popoverのbuttonが残っています")
        }
        _ = try ui.waitFor(identifier: "life-log.inspector-toggle")
        _ = try ui.waitFor(identifier: "life-log.day-map")
        try ui.press(identifier: "life-log.calendar-event-demo-event-1")
        _ = try ui.waitFor(identifier: "life-log.timeline-event-demo-event-1")
        try ui.press(identifier: "life-log.event-select-demo-event-1")
        _ = try ui.waitFor(identifier: "life-log.event-details.join")
        _ = try ui.waitFor(identifier: "life-log.event-details.guests")
        _ = try ui.waitFor(identifier: "life-log.event-details.rooms")
        try ui.press(identifier: "life-log.event-details.description-toggle")
        _ = try ui.waitForString(identifier: "life-log.event-details.description") { $0.contains("電話で参加") }
        try ui.press(identifier: "life-log.event-select-demo-event-2")
        _ = try ui.waitForString(identifier: "life-log.event-details.title") { $0.contains("デザインレビュー") }
        guard !ui.exists(identifier: "life-log.event-details.description-toggle"),
              !ui.exists(identifier: "life-log.event-details.rooms") else {
            throw UIE2EError.assertion("別の予定を選んだ後も前の予定の詳細が残っています")
        }
        try ui.press(identifier: "life-log.event-details.close")
        _ = try ui.waitFor(identifier: "life-log.day-map")
        try ui.press(identifier: "life-log.search")
        try ui.setValue("オンボーディング", identifier: "life-log.search-input")
        try ui.press(identifier: "life-log.search-result-memo-demo-memo-1")
        for removed in ["life-log.open-all-todos", "life-log.refresh-summary", "life-log.summary-markdown"] {
            guard !ui.exists(identifier: removed) else {
                throw UIE2EError.assertion("廃止したTODO・要約の表示が残っています: \(removed)")
            }
        }
        try ui.press(identifier: "main.section.history")
        _ = try ui.waitFor(identifier: "history.root")
        try ui.press(identifier: "main.section.lifeLog")
        let memo = "メイン画面から追加したE2Eメモ"
        try ui.setValue(memo, identifier: "life-log.memo-input")
        try ui.press(identifier: "life-log.memo-send")
        try ui.waitFor(text: memo)
        try ui.press(identifier: "life-log.export-day")
        _ = try ui.waitFor(identifier: "export.sheet")
        let initialPreview = try ui.waitForString(identifier: "export.preview") {
            $0.contains("オンボーディングは3つの機能を順番に紹介する")
        }
        guard initialPreview.contains("プロダクト朝会") else {
            throw UIE2EError.assertion("予定・メモが日別書き出しへ届いていません")
        }
        guard try ui.stringValue(identifier: "export.include.memo") == "オン" else {
            throw UIE2EError.assertion("メモが初期状態で選択されていません")
        }
        try ui.press(identifier: "export.include.memo")
        guard try ui.stringValue(identifier: "export.include.memo") == "オフ" else {
            throw UIE2EError.assertion("書き出し項目の選択解除が反映されません")
        }
        let updatedPreview = try ui.waitForString(identifier: "export.preview") {
            !$0.contains("オンボーディングは3つの機能を順番に紹介する")
        }
        guard updatedPreview.contains("プロダクト朝会") else {
            throw UIE2EError.assertion("選択したままの予定が書き出しプレビューから消えました")
        }
        guard try ui.stringValue(identifier: "export.include.voice-input") == "オン" else {
            throw UIE2EError.assertion("音声入力が独立した書き出し項目になっていません")
        }
        try ui.press(identifier: "export.include.voice-input")
        _ = try ui.waitForString(identifier: "export.preview") { !$0.contains("レビューで確認したい観点を三つに整理する") }
        try ui.press(identifier: "export.close")
        terminateTestApp()
    }

    @MainActor
    private static func runEmptyDayCUJ(appURL: URL) async throws {
        print("CUJ 2: 記録がない状態でも記録操作と書き出しへ届く")
        let app = try await launch(appURL, arguments: ["--lore-ui-test-empty"])
        let ui = AXDriver(pid: app.processIdentifier)

        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        try ui.press(identifier: "life-log.export-day")
        _ = try ui.waitFor(identifier: "export.sheet")
        try ui.press(identifier: "export.close")
    }

    @MainActor
    private static func runAISettingsCUJ(appURL: URL) async throws {
        print("CUJ 3: 保存容量、カレンダー、ライフログ、モードの設定を確認する")
        var app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-privacy"])
        var ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "privacy.storage")

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-calendar"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "calendar.settings.root")
        _ = try ui.waitFor(identifier: "calendar.refresh")
        try ui.waitFor(text: "記録しないカレンダー")

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-life-log"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "life-log.voice-memo-hotkey")

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-modes"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "mode.row.builtin.default")
        _ = try ui.waitFor(identifier: "mode.row.builtin.chat")
        guard !ui.exists(identifier: "mode.row.builtin.ai-agent") else {
            throw UIE2EError.assertion("廃止したAI Agentモードが残っています")
        }

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-life-log-ai"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "life-log-ai.settings.root")
        try ui.waitFor(text: "いまはオフなので、何も送りません。")
        guard try ui.stringValue(identifier: "life-log-ai.requests-today") == "0" else {
            throw UIE2EError.assertion("ライフログAIがオフなのにリクエストが数えられています")
        }
    }

    @MainActor
    private static func runEventNotesCUJ(appURL: URL) async throws {
        print("CUJ 5: 予定の下に保存済みのAIノートを読み、元の発話へ移動し、書き出しに含める")
        let app = try await launch(appURL, arguments: ["--lore-screenshot-demo"])
        let ui = AXDriver(pid: app.processIdentifier)
        let notes = "life-log.event-notes-demo-event-1"
        _ = try ui.waitFor(identifier: notes)
        _ = try ui.waitFor(identifier: "\(notes).generated-mark")
        _ = try ui.waitFor(identifier: "\(notes).provider")
        _ = try ui.waitFor(identifier: "life-log.inspector-ai-note-demo-event-1")
        try ui.press(identifier: "\(notes).item-decisions-0")
        try ui.waitFor(text: "検索とエクスポートが揃ったので、今日は初回体験の流れを確認します。")

        try ui.press(identifier: "life-log.export-day")
        _ = try ui.waitFor(identifier: "export.sheet")
        guard try ui.stringValue(identifier: "export.include.ai-notes") == "オフ" else {
            throw UIE2EError.assertion("AIノートが書き出しの初期状態で選択されています")
        }
        _ = try ui.waitForString(identifier: "export.preview") { !$0.contains("今日は初回体験の流れの確認を最優先にする") }
        try ui.press(identifier: "export.include.ai-notes")
        _ = try ui.waitForString(identifier: "export.preview") {
            $0.contains("今日は初回体験の流れの確認を最優先にする") && $0.contains("AIが生成したノート")
        }
        try ui.press(identifier: "export.close")
        terminateTestApp()
    }

    @MainActor
    private static func runDailyDigestCUJ(appURL: URL) async throws {
        print("CUJ 6: 1日のまとめを日の先頭とinspectorで読み、元の記録へ移動し、検索でAIの生成物として見つける")
        let app = try await launch(appURL, arguments: ["--lore-screenshot-demo"])
        let ui = AXDriver(pid: app.processIdentifier)
        let digest = "life-log.daily-digest"
        _ = try ui.waitFor(identifier: digest)
        for part in ["generated-mark", "provider", "copy", "regenerate", "delete", "item-summary-0", "item-commitments-0", "item-requests-0", "item-decisions-0"] {
            _ = try ui.waitFor(identifier: "\(digest).\(part)")
        }
        _ = try ui.waitFor(identifier: "\(digest).compact")
        _ = try ui.waitFor(identifier: "\(digest).compact.item-summary-0")
        guard !ui.exists(identifier: "\(digest).compact.item-commitments-0") else {
            throw UIE2EError.assertion("inspectorのまとめに要約以外の項目が出ています")
        }
        try ui.press(identifier: "\(digest).item-decisions-0")
        try ui.waitFor(text: "次のベータではショートカットから書き出して、好きなLLMへ渡せることも試します。")

        try ui.press(identifier: "life-log.search")
        try ui.setValue("ショートカットからの書き出し", identifier: "life-log.search-input")
        _ = try ui.waitFor(identifier: "life-log.search-result-generated-demo-digest-today")
        try ui.press(identifier: "life-log.search-result-generated-demo-digest-today")
        _ = try ui.waitFor(identifier: digest)
        terminateTestApp()
    }

    @MainActor
    private static func runMorningDigestCUJ(appURL: URL) async throws {
        print("CUJ 7: 翌朝の最初の表示で昨日のまとめを一度だけ見せる")
        let app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-demo-morning-digest"])
        let ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "life-log.morning-digest")
        _ = try ui.waitFor(identifier: "life-log.daily-digest.read-only.omitted")
        guard !ui.exists(identifier: "life-log.daily-digest.read-only.delete") else {
            throw UIE2EError.assertion("昨日のまとめの画面に削除が出ています")
        }
        try ui.press(identifier: "life-log.morning-digest.close")
        try ui.press(identifier: "main.section.history")
        _ = try ui.waitFor(identifier: "history.root")
        try ui.press(identifier: "main.section.lifeLog")
        _ = try ui.waitFor(identifier: "life-log.daily-digest")
        try await Task.sleep(for: .seconds(1))
        guard !ui.exists(identifier: "life-log.morning-digest") else {
            throw UIE2EError.assertion("昨日のまとめが二度目の表示でも出ています")
        }
        terminateTestApp()
    }

    @MainActor
    private static func runJoinMeetingCUJ(appURL: URL) async throws {
        print("CUJ 8: ミニウィンドウで次の会議の参加を押すと、そのリンクだけが開き、録音状態は変わらない")
        let launchedAt = Date()
        var app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-demo-meeting-soon", "--lore-demo-recurring-now"])
        var ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        try ui.pressMenuItem(title: "ライフログ ミニウィンドウ")
        try ui.waitFor(text: "デザイン同期")
        let countdown = try ui.waitForString(identifier: "life-log-mini.meeting.countdown") { $0.hasSuffix("分後") }
        guard countdown == "2分後" || countdown == "1分後" else {
            throw UIE2EError.assertion("1分あまり後に始まる会議の残り時間が違います: \(countdown)")
        }
        // The weekly 1:1 in progress is not the meeting to join next, so its pinned card has no Join.
        guard !ui.exists(identifier: "life-log-mini.current-event.join") else {
            throw UIE2EError.assertion("次に参加する会議ではない進行中の予定に参加ボタンがあります")
        }
        let captureBefore = try ui.label(identifier: "life-log-mini.capture-toggle")
        guard captureBefore == "ライフログ録音を開始" else {
            throw UIE2EError.assertion("ライフログが停止状態で始まっていません: \(captureBefore ?? "-")")
        }
        try ui.press(identifier: "life-log-mini.meeting.join")
        try await expectLogged("Join opened https://example.zoom.us/j/85550100123?pwd=demo-soon", since: launchedAt)
        guard try ui.label(identifier: "life-log-mini.capture-toggle") == captureBefore else {
            throw UIE2EError.assertion("参加を押したらライフログの録音状態が変わりました")
        }

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-ui-test-settings-calendar"])
        ui = AXDriver(pid: app.processIdentifier)
        guard try !ui.isOn(identifier: "calendar.meeting-notification") else {
            throw UIE2EError.assertion("会議の1分前の通知が既定でオンです")
        }
        terminateTestApp()
    }

    /// The demo build logs a join link instead of opening the user's browser.
    private static func expectLogged(_ message: String, since start: Date) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--style", "compact", "--start", formatter.string(from: start.addingTimeInterval(-1)),
                                 "--predicate", "subsystem == \"dev.agatan.Lore\" AND category == \"ui\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if output.contains(message) { return }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        throw UIE2EError.assertion("ログに出ていません: \(message)")
    }

    @MainActor
    private static func runOnboardingCUJ(appURL: URL) async throws {
        print("CUJ 4: 初回案内で音声入力を試す段階を飛ばしても、ライフログへ進んでも完了する")
        var app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-screenshot-onboarding"])
        var ui = AXDriver(pid: app.processIdentifier)
        try ui.press(identifier: "onboarding.next")
        _ = try ui.waitFor(identifier: "onboarding.try.hotkey")
        _ = try ui.waitFor(identifier: "onboarding.try.field")
        if ui.exists(identifier: "onboarding.try.blocker.microphone") || ui.exists(identifier: "onboarding.try.blocker.accessibility") {
            try ui.press(identifier: "onboarding.try.back-to-permissions")
            try ui.press(identifier: "onboarding.next")
        }
        try ui.press(identifier: "onboarding.try.skip")
        try ui.press(identifier: "onboarding.finish")
        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        guard !ui.exists(identifier: "onboarding.next") else {
            throw UIE2EError.assertion("あとでを選んでも初回案内が閉じません")
        }

        app = try await launch(appURL, arguments: ["--lore-screenshot-demo", "--lore-screenshot-onboarding"])
        ui = AXDriver(pid: app.processIdentifier)
        try ui.press(identifier: "onboarding.next")
        try ui.press(identifier: "onboarding.try.skip")
        try ui.press(identifier: "onboarding.start-life-log")
        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        try ui.waitFor(text: "ライフログの音声を保存しますか？")
    }

    @MainActor
    private static func launch(
        _ url: URL,
        arguments: [String],
        activates: Bool = true
    ) async throws -> NSRunningApplication {
        terminateTestApp()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = activates
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            guard app.bundleIdentifier == uiTestBundleIdentifier else {
                throw UIE2EError.launch(
                    "テスト専用bundleではないprocessが返されました: \(app.bundleIdentifier ?? "不明")"
                )
            }
            return app
        } catch {
            throw UIE2EError.launch("LoreUITestsを起動できません: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func terminateTestApp() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: uiTestBundleIdentifier) {
            app.terminate()
        }
        let gracefulDeadline = Date().addingTimeInterval(2)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: uiTestBundleIdentifier).isEmpty,
              Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: uiTestBundleIdentifier) where !app.isTerminated {
            app.forceTerminate()
        }
        let forcedDeadline = Date().addingTimeInterval(2)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: uiTestBundleIdentifier).isEmpty,
              Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
