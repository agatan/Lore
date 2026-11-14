#if DEBUG
import AppKit
import ScreenCaptureKit

/// 開発用: `--koe-snapshot <dir>`で起動すると主要windowを自身で描画してPNGへ保存し、終了する。
/// 画面収録の権限なしでUIの見た目を確認するためのもので、Release buildには含めない。
@MainActor
enum DebugSnapshotter {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--koe-snapshot"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// `--koe-snapshot-appearance dark|light`で外観を固定して撮る。省略時はsystemの外観。
    static var appearance: NSAppearance? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--koe-snapshot-appearance"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
    }

    static func run(env: AppEnvironment, presenter: KoeWindowPresenter, into directory: URL) async {
        if let appearance { NSApp.appearance = appearance }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 自動記録の表示も確認できるよう、現在時刻を含まない時間帯で有効にする。
            let minute = (Calendar.current.component(.hour, from: Date()) + 2) % 24 * 60
            env.updateLifeLogSchedule(LifeLogSchedule(isEnabled: true, startMinute: minute, endMinute: (minute + 9 * 60) % (24 * 60)))
            await settle(3)
            try await capture(KoeWindow.main, as: "main-life-log", into: directory)
            env.mainSection = .history
            await settle(1)
            try await capture(KoeWindow.main, as: "main-history", into: directory)
            for section in SettingsSection.allCases {
                presenter.showSettings(section)
                await settle(1)
                try await capture(KoeWindow.settings, as: "settings-\(section.rawValue)", into: directory)
            }
            presenter.toggleLifeLogMini()
            await settle(1.5)
            try await capture(KoeWindow.lifeLogMini, as: "life-log-mini", into: directory)
        } catch {
            KoeLog.ui.error("UI snapshotに失敗: \(error.localizedDescription, privacy: .public)")
        }
        exit(0)
    }

    private static func settle(_ seconds: Double) async {
        do { try await Task.sleep(for: .seconds(seconds)) } catch {}
    }

    /// 自process内のwindowだけを対象にするため、画面収録の権限を要求しない。
    private static func capture(_ identifier: String, as name: String, into directory: URL) async throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier && $0.isVisible }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(identifier) windowが表示されていません"])
        }
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(identifier) windowを取得できません"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(name)をPNGへ変換できません"])
        }
        try data.write(to: directory.appending(path: "\(name).png"))
    }
}
#endif
