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
private enum KoeUIE2E {
    private static let uiTestBundleIdentifier = "dev.agatan.Koe.UIE2E"

    @MainActor
    static func main() async {
        do {
            let appURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/KoeUITests.app")
            guard Bundle(url: appURL)?.bundleIdentifier == uiTestBundleIdentifier else {
                throw UIE2EError.assertion(
                    "UI E2Eはテスト専用bundleでのみ実行できます: \(appURL.path)"
                )
            }
            guard AXIsProcessTrusted() else { throw UIE2EError.accessibilityPermission }
            try await runDailyReviewCUJ(appURL: appURL)
            try await runEmptyDayCUJ(appURL: appURL)
            try await runAISettingsCUJ(appURL: appURL)
            terminateTestApp()
            print("✓ UI E2E: 3 CUJs passed")
        } catch {
            fputs("✗ UI E2E: \(error.localizedDescription)\n", stderr)
            terminateTestApp()
            exit(1)
        }
    }

    @MainActor
    private static func runDailyReviewCUJ(appURL: URL) async throws {
        print("CUJ 1: ライフログを検索して移動し、音声入力へ切り替え、日別書き出しを調整する")
        let app = try await launch(appURL, arguments: ["--koe-screenshot-demo"], activates: false)
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
        try ui.press(identifier: "life-log.calendar-events")
        try ui.press(identifier: "life-log.calendar-event-demo-event-1")
        _ = try ui.waitFor(identifier: "life-log.timeline-event-demo-event-1")
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
            $0.contains("オンボーディングは3つの価値が順番に伝わる構成にする")
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
            !$0.contains("オンボーディングは3つの価値が順番に伝わる構成にする")
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
        let app = try await launch(appURL, arguments: ["--koe-ui-test-empty"])
        let ui = AXDriver(pid: app.processIdentifier)

        _ = try ui.waitFor(identifier: "life-log.capture-toggle")
        try ui.press(identifier: "life-log.export-day")
        _ = try ui.waitFor(identifier: "export.sheet")
        try ui.press(identifier: "export.close")
    }

    @MainActor
    private static func runAISettingsCUJ(appURL: URL) async throws {
        print("CUJ 3: 保存容量、カレンダー、ライフログ、モードの設定を確認する")
        var app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-privacy"])
        var ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "privacy.storage")

        app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-calendar"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "calendar.settings.root")
        _ = try ui.waitFor(identifier: "calendar.refresh")

        app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-life-log"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "life-log.voice-memo-hotkey")

        app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-modes"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "mode.row.builtin.default")
        _ = try ui.waitFor(identifier: "mode.row.builtin.chat")
        guard !ui.exists(identifier: "mode.row.builtin.ai-agent") else {
            throw UIE2EError.assertion("廃止したAI Agentモードが残っています")
        }
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
            throw UIE2EError.launch("KoeUITestsを起動できません: \(error.localizedDescription)")
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
