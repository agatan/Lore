import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// イベントタップのコールバック。
///
/// クロージャにすると Swift 6 では @Sendable 扱いになり `CGEvent` を受け取れないため、
/// トップレベルの C 関数として置く。タップは main run loop に載せているので main で走る。
private func koeEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        monitor.handle(type: type, event: event)
    }
}

/// グローバルホットキーの監視(要アクセシビリティ権限)。
///
/// 押下・離上の生イベントだけを流し、トグル / push-to-talk の解釈は
/// `HotkeyGestureInterpreter`(純粋ドメイン)に任せる。
@MainActor
public final class HotkeyMonitor {
    public enum Failure: LocalizedError {
        case notTrusted
        case tapCreationFailed

        public var errorDescription: String? {
            switch self {
            case .notTrusted: "アクセシビリティの許可が必要です"
            case .tapCreationFailed: "キーボード監視を開始できませんでした"
            }
        }
    }

    /// 押下・離上イベント。
    public var onEvent: ((HotkeyPhysicalEvent) -> Void)?
    /// 録音中の Esc。true を返すとイベントを飲み込む。
    public var onEscape: (() -> Bool)?

    public private(set) var binding: HotkeyBinding = .default
    public private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressStart: ContinuousClock.Instant?

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        guard Permissions.isAccessibilityGranted else { throw Failure.notTrusted }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: koeEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw Failure.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        pressStart = nil
        isRunning = false
    }

    public func update(binding: HotkeyBinding) {
        self.binding = binding
        pressStart = nil
    }

    /// 権限が付与された直後などに呼び直す。
    public func restart() {
        stop()
        try? start()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough

        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // 録音中の Esc は破棄キャンセル。前面アプリに漏らさない(FR-1.4)。
            if code == 0x35, onEscape?() == true {
                return nil
            }
            guard case .key(let bound, let modifiers) = binding, code == bound else { return passthrough }
            guard event.flags.rawValue & modifiers == modifiers else { return passthrough }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            beginPress()
            return nil

        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard case .key(let bound, _) = binding, code == bound else { return passthrough }
            endPress()
            return nil

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard case .modifier(let key) = binding, code == key.keyCode else { return passthrough }
            let isDown = event.flags.rawValue & key.deviceFlagBit != 0
            if isDown {
                beginPress()
            } else {
                endPress()
            }
            // 修飾キーは他アプリの操作に必要なので必ず素通しする。
            return passthrough

        default:
            return passthrough
        }
    }

    private func beginPress() {
        pressStart = ContinuousClock.now
        onEvent?(.pressed)
    }

    private func endPress() {
        let held: Duration = pressStart.map { ContinuousClock.now - $0 } ?? .zero
        pressStart = nil
        onEvent?(.released(heldFor: held))
    }
}
