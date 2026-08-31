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
    @MainActor
    static func main() async {
        do {
            guard AXIsProcessTrusted() else { throw UIE2EError.accessibilityPermission }
            let appURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/Koe.app")
            try await runDailyReviewCUJ(appURL: appURL)
            try await runEmptyTodoCUJ(appURL: appURL)
            try await runAISettingsCUJ(appURL: appURL)
            terminateKoe()
            print("✓ UI E2E: 3 CUJs passed")
        } catch {
            fputs("✗ UI E2E: \(error.localizedDescription)\n", stderr)
            terminateKoe()
            exit(1)
        }
    }

    @MainActor
    private static func runDailyReviewCUJ(appURL: URL) async throws {
        print("CUJ 1: ライフログのTODO出典を確認し、音声入力へ切り替え、日別書き出しを調整する")
        let app = try await launch(appURL, arguments: ["--koe-screenshot-demo"])
        let ui = AXDriver(pid: app.processIdentifier)

        _ = try ui.waitFor(identifier: "main.section-picker")
        _ = try ui.waitFor(identifier: "life-log.voice-memo")
        try ui.press(identifier: "life-log.todo-source-demo-todo-1")
        try ui.press(identifier: "main.section.history")
        _ = try ui.waitFor(identifier: "history.root")
        try ui.press(identifier: "main.section.lifeLog")
        let memo = "メイン画面から追加したE2Eメモ"
        try ui.setValue(memo, identifier: "life-log.memo-input")
        try ui.press(identifier: "life-log.memo-send")
        try ui.waitFor(text: memo)
        try ui.press(identifier: "life-log.export-day")
        _ = try ui.waitFor(identifier: "export.sheet")
        let initialPreview = try ui.stringValue(identifier: "export.preview") ?? ""
        guard initialPreview.contains("オンボーディングは3つの価値が順番に伝わる構成にする"),
              initialPreview.contains("プロダクト朝会"),
              initialPreview.contains("初回体験とベータ公開に向けて") else {
            throw UIE2EError.assertion("予定・メモ・要約が日別書き出しへ届いていません")
        }
        guard try ui.stringValue(identifier: "export.include.summary") == "オン" else {
            throw UIE2EError.assertion("要約が初期状態で選択されていません")
        }
        try ui.press(identifier: "export.include.summary")
        guard try ui.stringValue(identifier: "export.include.summary") == "オフ" else {
            throw UIE2EError.assertion("書き出し項目の選択解除が反映されません")
        }
        let updatedPreview = try ui.stringValue(identifier: "export.preview") ?? ""
        guard !updatedPreview.contains("初回体験とベータ公開に向けて") else {
            throw UIE2EError.assertion("除外した要約が書き出しプレビューに残っています")
        }
        try ui.press(identifier: "export.close")
        terminateKoe()
    }

    @MainActor
    private static func runEmptyTodoCUJ(appURL: URL) async throws {
        print("CUJ 2: TODOがない日に管理画面を開き、空状態を確認する")
        let app = try await launch(appURL, arguments: ["--koe-ui-test-empty"])
        let ui = AXDriver(pid: app.processIdentifier)

        try ui.press(identifier: "life-log.open-all-todos")
        _ = try ui.waitFor(identifier: "todo-manager.root")
        _ = try ui.waitFor(identifier: "todo-manager.empty")
    }

    @MainActor
    private static func runAISettingsCUJ(appURL: URL) async throws {
        print("CUJ 3: 利用状況とモードを確認する")
        var app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-usage"])
        var ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "usage.overview")
        _ = try ui.waitFor(identifier: "usage.recording")
        _ = try ui.waitFor(identifier: "usage.api")
        _ = try ui.waitFor(identifier: "usage.storage")

        app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-calendar"])
        ui = AXDriver(pid: app.processIdentifier)
        _ = try ui.waitFor(identifier: "calendar.settings.root")
        _ = try ui.waitFor(identifier: "calendar.refresh")

        app = try await launch(appURL, arguments: ["--koe-screenshot-demo", "--koe-ui-test-settings-life-log-general"])
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
    private static func launch(_ url: URL, arguments: [String]) async throws -> NSRunningApplication {
        terminateKoe()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        do {
            return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw UIE2EError.launch("Koeを起動できません: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func terminateKoe() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agatan.Koe") {
            app.terminate()
        }
        let gracefulDeadline = Date().addingTimeInterval(2)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agatan.Koe").isEmpty,
              Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agatan.Koe") where !app.isTerminated {
            app.forceTerminate()
        }
        let forcedDeadline = Date().addingTimeInterval(2)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.agatan.Koe").isEmpty,
              Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
