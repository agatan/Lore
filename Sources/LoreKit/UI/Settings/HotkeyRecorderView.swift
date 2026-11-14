import AppKit
import SwiftUI

/// ホットキーの割り当てを記録する。
///
/// アプリ自身がフォーカスを持っている間だけなので、イベントタップではなく
/// ローカルモニタで拾う(アクセシビリティ権限が無くても設定できる)。
/// 「⌥ 単体」と「⌥D」の見分けは `HotkeyRecorder` に任せる。
struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding
    /// 記録の開始・終了。記録中はグローバル監視を止めてもらう。
    var setCaptureMode: (Bool) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var recorder = HotkeyRecorder()
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isRecording ? "record.circle" : "keyboard")
                            .font(.system(size: 11))
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? LoreTheme.recording : nil)

                if isRecording {
                    Button("やめる") { stop() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                } else {
                    Menu("よく使うキー") {
                        ForEach(ModifierKey.allCases) { key in
                            Button(key.displayName) { binding = .modifier(key) }
                        }
                        Divider()
                        Button("F13") { binding = .key(code: 0x69, modifiers: 0) }
                        Button("F14") { binding = .key(code: 0x6B, modifiers: 0) }
                        Button("⌃⌥Space") { binding = .key(code: 0x31, modifiers: 0x0004_0000 | 0x0008_0000) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if let rejection {
                Text(rejection)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LoreTheme.warning)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
            }
        }
        .onDisappear { stop() }
    }

    /// 記録中は「押されている修飾キー」を出して、まだ続けられることを伝える。
    private var label: String {
        guard isRecording else { return binding.displayName }
        if let pending = recorder.pendingModifier {
            return "\(pending.displayName) + キー、または離して確定"
        }
        return "キーを押してください…"
    }

    private func start() {
        isRecording = true
        rejection = nil
        recorder.reset()
        setCaptureMode(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event) }
            // 記録中のキーはアプリに渡さない(∂ などが入力されるのを防ぐ)。
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        let step: HotkeyRecorder.Step
        switch event.type {
        case .flagsChanged:
            step = recorder.modifierChanged(keyCode: event.keyCode, flags: flags)
        case .keyDown:
            if event.keyCode == HotkeyRecorder.escapeKeyCode {
                stop()
                return
            }
            step = recorder.keyDown(keyCode: event.keyCode, flags: flags)
        default:
            step = .ignored
        }

        switch step {
        case .captured(let captured):
            binding = captured
            stop()
        case .rejected(let reason):
            rejection = reason
        case .waiting, .ignored:
            break
        }
    }

    private func stop() {
        isRecording = false
        recorder.reset()
        // 記録を抜けるどの経路でも必ず戻す(ここを落とすとホットキーが死ぬ)。
        setCaptureMode(false)
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
