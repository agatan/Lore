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
///
/// **コールバックの中で重い処理をしてはいけない。**
/// イベントタップのコールバックが規定時間内に返らないと OS がタップを無効化し、
/// 以降のキーが前面アプリへ素通しする。⌥ 単体のような修飾キーなら素通しは無害だが、
/// ⌥D のように文字を生む割り当てだと、その文字(∂)が入力されてしまう。
/// そのため通知は run loop の次のターンへ回し、ここでは消費するかどうかだけを決める(C-57)。
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

    /// 押下・離上イベント。run loop の次のターンで呼ばれる。
    public var onEvent: ((HotkeyPhysicalEvent) -> Void)?
    /// Esc を飲み込むべきか。**この場合だけは同期で判定する**(消費するかどうかを
    /// その場で決めなければならないため)。安価な状態参照だけにして、実際の中止処理は
    /// 実装側が次のターンへ回す。
    public var shouldSwallowEscape: (() -> Bool)?

    public private(set) var binding: HotkeyBinding = .default
    public private(set) var isRunning = false
    /// 監視を一時停止しているか。設定画面でホットキーを記録している間は止める。
    public private(set) var isSuspended = false

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

    /// 一時停止・再開。
    ///
    /// ホットキーを記録している間は止める。止めないと、記録のために押したキーが
    /// **いま設定されているホットキーに一致して録音が始まってしまう**。
    /// タップ自体は生かしたまま素通しにするので、権限の再取得は起きない。
    /// 素通ししたキーは、記録中は前面(Koe 自身)のローカルモニタが受け取って消費する。
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        pressStart = nil
    }

    /// 権限が付与された直後などに呼び直す。
    public func restart() {
        stop()
        try? start()
    }

    /// テストから消費判定を検証するため internal。
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 無効化されている間のキーは前面アプリへ抜けている。
            // 原因を追えるようにログへ残す(コールバックが遅いと必ずここへ来る)。
            KoeLog.hotkey.error(
                "イベントタップが無効化されました(\(type == .tapDisabledByTimeout ? "timeout" : "userInput", privacy: .public))。再有効化します"
            )
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough

        // 記録中は何も解釈せず、何も消費しない。
        case _ where isSuspended:
            return passthrough

        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // 録音中の Esc は破棄キャンセル。前面アプリに漏らさない(FR-1.4)。
            if code == 0x35, shouldSwallowEscape?() == true {
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
        notify(.pressed)
    }

    private func endPress() {
        let held: Duration = pressStart.map { ContinuousClock.now - $0 } ?? .zero
        pressStart = nil
        notify(.released(heldFor: held))
    }

    /// 通知を run loop の次のターンへ回す。
    ///
    /// タップのコールバックを即座に返すためで、`DispatchQueue.main.async` を選ぶのは
    /// FIFO が保証されるから。押下と離上の順序が入れ替わるとトグル / PTT の判定が壊れる。
    private func notify(_ event: HotkeyPhysicalEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}
