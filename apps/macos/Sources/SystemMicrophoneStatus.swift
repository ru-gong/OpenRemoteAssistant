import Foundation
import CoreAudio

/// Audio-device metadata only. No input stream, microphone permission request,
/// level measurement, recording, UID display, or system-default mutation.
struct SystemMicrophoneStatus {
    let name: String
    let detail: String

    static func read() -> Self {
        let inputs = deviceIDs().compactMap { id -> InputDevice? in
            guard channelCount(id) > 0 else { return nil }
            return InputDevice(id: id, name: deviceName(id),
                transport: scalar(id, kAudioDevicePropertyTransportType) ?? 0,
                alive: scalar(id, kAudioDevicePropertyDeviceIsAlive) == 1)
        }
        let names = Array(Set(inputs.filter(\.alive).map(\.name))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let availability = names.isEmpty ? "未检测到可用输入设备。" : "可用输入：\(names.joined(separator: "、"))。"
        let settings = "可在系统设置 → 声音 → 输入中选择；转写软件也可能有独立输入设置。"
        guard let defaultID = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              defaultID != kAudioObjectUnknown else {
            return Self(name: "未检测到系统默认输入", detail: availability + settings)
        }
        guard let selected = inputs.first(where: { $0.id == defaultID }), selected.alive else {
            return Self(name: deviceName(defaultID), detail: "当前默认输入已断开或没有可用输入通道。" + availability + settings)
        }
        let kind: String
        switch selected.transport {
        case kAudioDeviceTransportTypeBuiltIn: kind = "内置麦克风。"
        case kAudioDeviceTransportTypeUSB: kind = "USB 音频输入。"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = "蓝牙音频输入。"
        case kAudioDeviceTransportTypeVirtual: kind = "当前默认输入是虚拟设备，请确认其来源，或在声音设置中选择实体麦克风。"
        case kAudioDeviceTransportTypeAggregate: kind = "当前默认输入是聚合设备，请确认其中的麦克风来源。"
        default: kind = "系统音频输入。"
        }
        return Self(name: selected.name, detail: kind + availability + settings)
    }

    private struct InputDevice {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
        let alive: Bool
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        let stride = MemoryLayout<AudioDeviceID>.size
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr,
              bytes > 0, bytes <= 65_536, Int(bytes) % stride == 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(bytes) / stride))
    }

    private static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &value) == noErr else { return nil }
        return value
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &value) == noErr, let value else {
            return "名称不可用的音频输入"
        }
        let name = (value.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名音频输入" : name
    }

    private static func channelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size, bytes <= 65_536 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
