#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// 開発用: `--lore-snapshot <dir>`で起動すると主要windowを自身で描画してPNGへ保存し、終了する。
/// 画面収録の権限なしでUIの見た目を確認するためのもので、Release buildには含めない。
@MainActor
enum DebugSnapshotter {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--lore-snapshot"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// `--lore-snapshot-appearance dark|light`で外観を固定して撮る。省略時はsystemの外観。
    static var appearance: NSAppearance? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--lore-snapshot-appearance"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
    }

    static func run(env: AppEnvironment, presenter: LoreWindowPresenter, into directory: URL) async {
        if let appearance { NSApp.appearance = appearance }
        env.settings.applicationLanguage = DemoCopy.current.language
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 自動記録の表示も確認できるよう、現在時刻を含まない時間帯で有効にする。
            let minute = (Calendar.current.component(.hour, from: Date()) + 2) % 24 * 60
            env.updateLifeLogSchedule(LifeLogSchedule(isEnabled: true, startMinute: minute, endMinute: (minute + 9 * 60) % (24 * 60)))
            await settle(3)
            try await capture(LoreWindow.main, as: "main-life-log", into: directory)
            if AppEnvironment.forcesOnboardingForScreenshot {
                exit(0)
            }
            // Toolbarのbuttonが切り替える値を変え、inspectorが閉じることを撮って確かめる。
            // SwiftUIはaccessibility clientがいないとtoolbarのAX要素を作らないため、buttonは押せない。
            UserDefaults.standard.set(false, forKey: "lifeLog.showsInspector")
            await settle(1)
            try await capture(LoreWindow.main, as: "main-life-log-inspector-hidden", into: directory)
            UserDefaults.standard.set(true, forKey: "lifeLog.showsInspector")
            if let empty = Calendar.current.date(byAdding: .day, value: -3, to: Date()) {
                await env.lifeLog.select(date: empty)
                await settle(1)
                try await capture(LoreWindow.main, as: "main-life-log-empty-day", into: directory)
                await env.lifeLog.followCurrentDay()
            }
            env.mainSection = .history
            await settle(1)
            try await capture(LoreWindow.main, as: "main-history", into: directory)
            for section in SettingsSection.allCases {
                presenter.showSettings(section)
                await settle(1)
                try await capture(LoreWindow.settings, as: "settings-\(section.rawValue)", into: directory)
            }
            presenter.toggleLifeLogMini()
            await settle(1.5)
            try await capture(LoreWindow.lifeLogMini, as: "life-log-mini", into: directory)
            try await captureHud(env: env, into: directory)
            try await captureHosted(
                MenuBarPanel(env: env)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(40)
                    .background(SnapshotWallpaper()),
                as: "menu-panel",
                into: directory
            )
            try writeMenuBarIcons(into: directory)
            try await captureHosted(
                LifeLogSearchSheet(env: env, initialQuery: DemoCopy.current.searchQuery)
                    .background(.background),
                as: "search",
                into: directory
            )
        } catch {
            LoreLog.ui.error("UI snapshotに失敗: \(error.localizedDescription, privacy: .public)")
            FileHandle.standardError.write(Data("UI snapshotに失敗: \(error.localizedDescription)\n".utf8))
        }
        exit(0)
    }

    /// HUDの各段階を、壁紙を模した背景の上に置いて撮る。Glassは同じwindow内の背景を透かす。
    private static func captureHud(env: AppEnvironment, into directory: URL) async throws {
        guard let coordinator = env.coordinator else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "音声入力の状態機械がまだありません"])
        }
        let levels: [Float] = (0..<DictationCoordinator.levelHistoryLength).map { index in
            let wave = abs(sin(Double(index) / 2.4)) * (0.35 + 0.65 * Double(index) / Double(DictationCoordinator.levelHistoryLength))
            return Float(0.08 + 0.8 * wave)
        }
        let copy = DemoCopy.current
        let states: [(String, SessionPhase, String, String?)] = [
            ("hud-recording-start", .recording, "", nil),
            ("hud-recording", .recording, copy.spoken, nil),
            ("hud-formatting", .formatting, copy.spoken, nil),
            ("hud-completed", .finished(.completed), "", nil),
            ("hud-skipped", .finished(.formattingSkipped(reason: "timeout")), copy.spoken, copy.skippedDetail),
        ]
        for (name, phase, transcript, detail) in states {
            coordinator.applyPreviewState(
                phase: phase,
                transcript: transcript,
                mode: BuiltinModes.defaultMode,
                levels: levels,
                elapsed: .seconds(7),
                detail: detail,
                inputDeviceName: DemoCopy.current.inputDevice
            )
            try await captureHosted(
                HudView(coordinator: coordinator, onCancel: {})
                    .frame(width: 560, height: 200, alignment: .bottom)
                    .background(SnapshotWallpaper()),
                as: name,
                into: directory
            )
        }
        coordinator.applyPreviewState(phase: .idle)
    }

    private static func captureHosted(_ view: some View, as name: String, into directory: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("lore.snapshot.\(name)")
        window.contentView = hosting
        window.level = .floating
        window.center()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle(1)
        try await capture("lore.snapshot.\(name)", as: name, into: directory)
    }

    /// 全状態のmenu barアイコンを、明暗のmenu barを模した帯へ4倍で並べる。
    private static func writeMenuBarIcons(into directory: URL) throws {
        let badges: [MenuBarStatusIcon.Badge?] = [nil, .recording, .processing, .done, .attention, .reconnecting]
        let live = MenuBarStatusIcon.image(level: 0.9, badge: .recording)
        let icons = badges.map { MenuBarStatusIcon.image(badge: $0) } + [live]
        let scale: CGFloat = 4
        let cell = NSSize(width: 40, height: 28)
        let stripSize = NSSize(width: cell.width * CGFloat(icons.count) * scale, height: cell.height * 2 * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(stripSize.width), pixelsHigh: Int(stripSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "menu barアイコンの描画先を作れません"])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (row, appearanceName) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            let appearance = NSAppearance(named: appearanceName)!
            let rowRect = NSRect(x: 0, y: CGFloat(row) * cell.height * scale, width: stripSize.width, height: cell.height * scale)
            (appearanceName == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
            rowRect.fill()
            appearance.performAsCurrentDrawingAppearance {
                for (index, icon) in icons.enumerated() {
                    let rect = NSRect(
                        x: (CGFloat(index) * cell.width + (cell.width - icon.size.width) / 2) * scale,
                        y: rowRect.minY + (cell.height - icon.size.height) / 2 * scale,
                        width: icon.size.width * scale,
                        height: icon.size.height * scale
                    )
                    if icon.isTemplate {
                        let tinted = NSImage(size: icon.size, flipped: false) { bounds in
                            icon.draw(in: bounds)
                            (appearanceName == .aqua ? NSColor.black : NSColor.white).set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    } else {
                        icon.draw(in: rect)
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "menu barアイコンをPNGへ変換できません"])
        }
        try data.write(to: directory.appending(path: "menu-bar-icons.png"))
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
/// HUDやpanelのガラスが透かす、デスクトップの壁紙の代わり。LP にも載るため、Lore の配色に合わせて無地にする。
private struct SnapshotWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.19)
            : Color(red: 0.86, green: 0.86, blue: 0.88)
    }
}
#endif
