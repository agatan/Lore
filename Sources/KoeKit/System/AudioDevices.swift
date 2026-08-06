import CoreAudio
import Foundation

/// いま録音に使っている入力デバイスの名前を引く。
///
/// **`AVAudioEngine` の入力ノードから引いてはいけない**。macOS では入力ノードは
/// `CADefaultDeviceAggregate-<pid>-<n>` という private な集約デバイスに束ねられ、
/// そこから名前を取るとその内部名がそのまま出てくる(実際に UI へ露出した)。
/// 集約が追っているのはシステム既定の入力なので、既定のデバイスを直接読むのが正しい。
enum AudioDevices {
    static func currentInputName() -> String? {
        defaultInputDevice().flatMap(name)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }
}
