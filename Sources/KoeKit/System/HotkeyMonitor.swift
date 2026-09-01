import AppKit
@preconcurrency import CoreGraphics
@preconcurrency import Carbon
import Foundation

private let koeHotKeySignature: OSType = 0x4B_6F_65_00 // "Koe\0"

private func koeRegisteredHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        monitor.handleRegisteredHotKey(id: hotKeyID.id, kind: kind)
    }
}

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
        case registrationFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .notTrusted: "アクセシビリティの許可が必要です"
            case .tapCreationFailed: "キーボード監視を開始できませんでした"
            case .registrationFailed(let status) where status == eventHotKeyExistsErr:
                "このホットキーは別のアプリが使用しています"
            case .registrationFailed(let status):
                "ホットキーを登録できませんでした (\(status))"
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
    private var registeredHotKey: EventHotKeyRef?
    private var registeredHotKeyHandler: EventHandlerRef?
    private var pressStart: ContinuousClock.Instant?
    private let registrationID: UInt32
    private static var nextRegistrationID: UInt32 = 1

    public init() {
        registrationID = Self.nextRegistrationID
        Self.nextRegistrationID &+= 1
    }

    public func start() throws {
        guard !isRunning else { return }

        switch binding {
        case .key(let code, let modifiers):
            try startRegisteredHotKey(code: code, modifiers: modifiers)
            // 組み合わせhotkey自体は登録APIで受ける。通常音声入力だけはEsc cancel用に
            // event tapも併設するが、作れなくても登録済みhotkeyは利用できる。
            if shouldSwallowEscape != nil, Permissions.isAccessibilityGranted {
                do {
                    try startEventTap()
                } catch {
                    KoeLog.hotkey.error("Esc監視を開始できません: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .modifier:
            guard Permissions.isAccessibilityGranted else { throw Failure.notTrusted }
            try startEventTap()
        }
        isRunning = true
    }

    private func startEventTap() throws {
        guard tap == nil else { return }

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
    }

    private func startRegisteredHotKey(code: UInt16, modifiers: UInt64) throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            koeRegisteredHotKeyCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr, let handler else {
            throw Failure.registrationFailed(handlerStatus)
        }

        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: koeHotKeySignature, id: registrationID)
        let registrationStatus = RegisterEventHotKey(
            UInt32(code),
            Self.carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKey
        )
        guard registrationStatus == noErr, let hotKey else {
            RemoveEventHandler(handler)
            throw Failure.registrationFailed(registrationStatus)
        }
        registeredHotKeyHandler = handler
        registeredHotKey = hotKey
    }

    public func stop() {
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
        }
        if let registeredHotKeyHandler {
            RemoveEventHandler(registeredHotKeyHandler)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        registeredHotKey = nil
        registeredHotKeyHandler = nil
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
    public func restart() throws {
        stop()
        try start()
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
            guard registeredHotKey == nil,
                  case .key(let bound, let modifiers) = binding,
                  code == bound else { return passthrough }
            guard event.flags.rawValue & modifiers == modifiers else { return passthrough }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            beginPress()
            return nil

        case .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard registeredHotKey == nil,
                  case .key(let bound, _) = binding,
                  code == bound else { return passthrough }
            guard pressStart != nil else { return passthrough }
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

    func handleRegisteredHotKey(id: UInt32, kind: UInt32) -> OSStatus {
        guard id == registrationID, !isSuspended else { return OSStatus(eventNotHandledErr) }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            beginPress()
            return noErr
        case UInt32(kEventHotKeyReleased):
            guard pressStart != nil else { return OSStatus(eventNotHandledErr) }
            endPress()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    static func carbonModifiers(from flags: UInt64) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags & 0x0004_0000 != 0 { modifiers |= UInt32(controlKey) }
        if flags & 0x0008_0000 != 0 { modifiers |= UInt32(optionKey) }
        if flags & 0x0002_0000 != 0 { modifiers |= UInt32(shiftKey) }
        if flags & 0x0010_0000 != 0 { modifiers |= UInt32(cmdKey) }
        return modifiers
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
