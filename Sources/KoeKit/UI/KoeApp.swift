import AppKit
import SwiftUI

/// アプリ本体。Dock アイコンを持たないメニューバー常駐アプリ(FR-8.1)。
public struct KoeApp: App {
    @State private var env = AppEnvironment()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(env: env)
        } label: {
            // ラベルは常駐中ずっと生きているので、ここで初期化を回す。
            MenuBarRoot(env: env)
        }
        .menuBarExtraStyle(.window)

        Window("Koe", id: KoeWindow.main) {
            MainWindowView(env: env)
                .koeWindow()
        }
        .defaultSize(width: 1_020, height: 640)
    }
}

public enum KoeWindow {
    public static let main = "koe.main"
}

/// メニューバーのアイコン + 起動処理。
private struct MenuBarRoot: View {
    var env: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @State private var hud: HudController?

    var body: some View {
        MenuBarLabel(coordinator: env.coordinator, settings: env.settings)
            .task { await bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        guard hud == nil else { return }
        let controller = HudController(coordinator: env.coordinator, settings: env.settings)
        controller.start()
        hud = controller

        await env.boot()

        // 起動直後は履歴を開く。ここが Koe の入口(設定へもここから移れる)。
        if env.settings.openHistoryAtLaunch {
            env.mainSection = .history
            openWindow(id: KoeWindow.main)
        }
    }
}
