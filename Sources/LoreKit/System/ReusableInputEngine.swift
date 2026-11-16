import AVFoundation
import CoreAudio
import Foundation

/// 録音のたびに `AVAudioEngine` を作り直さず、同じ既定入力デバイスの間は使い回す。
///
/// 新しいengineの `inputNode` に初めて触ると、macOSはBluetooth機器の音声形式の切り替えを待つ。
/// ライフログと音声入力のように別のengineが同じ機器をすでに使っていると変更通知が来ず、
/// メインスレッドが約3秒止まる(`SetBluetoothAudioFormatAndWait ... timed out`)。
/// その間は録音・効果音・ホットキー処理がすべて止まり、押した直後の発話が欠ける。
/// 既定入力が変わったときと構成変更が起きたときだけ作り直し、入力形式の食い違いは持ち越さない。
@MainActor
final class ReusableInputEngine {
    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID?
    private var configurationObserver: (any NSObjectProtocol)?

    /// 使い終わったら `stop()` を呼ぶ。tapと接続はここで外すので、次の利用者は空のgraphから組み立てる。
    func acquire() -> AVAudioEngine {
        let currentDevice = AudioDevices.defaultInputDevice()
        if let engine, currentDevice != nil, currentDevice == deviceID { return engine }
        discard()
        let engine = AVAudioEngine()
        self.engine = engine
        deviceID = currentDevice
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidate(engineID) }
        }
        return engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.disconnectNodeOutput(engine.inputNode)
    }

    /// 起動に失敗したengineは状態が分からないため、次回は作り直す。
    func discard() {
        stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
        deviceID = nil
    }

    /// 録音中なら各captureが停止と再接続を担うため、ここでは次回の取得で作り直す印だけを付ける。
    private func invalidate(_ changed: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == changed else { return }
        deviceID = nil
    }
}
