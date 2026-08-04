import AppKit
import SwiftUI

/// ホットキーの割り当てを記録する。
///
/// アプリ自身がフォーカスを持っている間だけなので、イベントタップではなく
/// ローカルモニタで拾う(アクセシビリティ権限が無くても設定できる)。
struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding
    @State private var isRecording = false
    @State private var monitor: Any?

    private static let modifierKeyCodes: [UInt16: ModifierKey] = Dictionary(
        uniqueKeysWithValues: ModifierKey.allCases.map { ($0.keyCode, $0) }
    )

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording ? stop() : start()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .font(.system(size: 11))
                    Text(isRecording ? "キーを押してください…" : binding.displayName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? KoeTheme.recording : nil)

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
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated {
                if let captured = Self.capture(event) {
                    binding = captured
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func capture(_ event: NSEvent) -> HotkeyBinding? {
        switch event.type {
        case .flagsChanged:
            guard let key = modifierKeyCodes[event.keyCode] else { return nil }
            // 押した瞬間だけを拾う(離上でも flagsChanged が来る)。
            guard event.modifierFlags.rawValue & UInt(key.deviceFlagBit) != 0
                || (key == .fn && event.modifierFlags.contains(.function))
            else { return nil }
            return .modifier(key)

        case .keyDown:
            if event.keyCode == 0x35 { return nil } // esc は取り消しに使うので割り当て不可
            let mask: UInt64 = 0x0004_0000 | 0x0008_0000 | 0x0002_0000 | 0x0010_0000
            let modifiers = UInt64(event.modifierFlags.rawValue) & mask
            return .key(code: event.keyCode, modifiers: modifiers)

        default:
            return nil
        }
    }
}
