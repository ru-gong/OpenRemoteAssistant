// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreAudio

struct SystemDefaultInputSnapshot: Equatable {
    let currentName: String
    let currentUID: String?
    let remoteIsDefault: Bool
    let canSelectRemote: Bool
    let canRestorePrevious: Bool
    let previousName: String?
}

enum SystemDefaultInputRestoreResult: Equatable {
    case restored(String)
    case nothingToRestore
    case currentChanged(String)
    case previousUnavailable
}

enum SystemDefaultInputMutationResult: Equatable {
    case confirmed
    case failed(OSStatus)
    case confirmationTimedOut
}

enum SystemDefaultInputError: LocalizedError, Equatable {
    case remoteUnavailable
    case currentUnavailable
    case currentIdentityUnavailable
    case propertyNotSettable
    case setFailed(OSStatus)
    case confirmationTimedOut
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .remoteUnavailable:
            return "遥控器麦克风输入端点未通过身份与通道校验；未更改系统默认输入。"
        case .currentUnavailable:
            return "无法读取当前系统默认输入；未更改系统设置。"
        case .currentIdentityUnavailable:
            return "当前默认输入的设备身份不可用；未更改系统设置。"
        case .propertyNotSettable:
            return "macOS 不允许当前进程更改默认输入；请在声音设置中手动选择。"
        case .setFailed(let status):
            return "macOS 更改默认输入失败（\(status)）；请在声音设置中手动选择。"
        case .confirmationTimedOut:
            return "已请求更改默认输入，但未及时收到 CoreAudio 的生效通知；状态尚未确认，请在声音设置中检查并手动恢复需要的输入。"
        case .verificationFailed:
            return "已请求更改默认输入，但回读未确认生效；请在声音设置中检查。"
        }
    }
}

protocol SystemDefaultInputAccess {
    func validatedRemoteInput() -> VoiceAudioDevice?
    func defaultInputID() -> AudioDeviceID?
    func uid(for device: AudioDeviceID) -> String?
    func name(for device: AudioDeviceID) -> String?
    func translate(uid: String) -> AudioDeviceID?
    func isUsableInput(_ device: AudioDeviceID) -> Bool
    func setDefaultInputAndWait(_ device: AudioDeviceID) -> SystemDefaultInputMutationResult
}

protocol PreviousDefaultInputStoring: AnyObject {
    var previousDefaultInputUID: String? { get set }
}

final class UserDefaultsPreviousDefaultInputStore: PreviousDefaultInputStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = "OpenRemotePreviousSystemDefaultInputUID") {
        self.defaults = defaults
        self.key = key
    }

    var previousDefaultInputUID: String? {
        get {
            guard let value = defaults.string(forKey: key), !value.isEmpty,
                  value.utf8.count <= 1_024 else { return nil }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty, newValue.utf8.count <= 1_024 {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

/// Changes only kAudioHardwarePropertyDefaultInputDevice after an explicit UI
/// action. It never changes the default output or system-effects output.
final class SystemDefaultInputController {
    private let access: SystemDefaultInputAccess
    private let storage: PreviousDefaultInputStoring

    init(access: SystemDefaultInputAccess = LiveSystemDefaultInputAccess(),
         storage: PreviousDefaultInputStoring = UserDefaultsPreviousDefaultInputStore()) {
        self.access = access
        self.storage = storage
    }

    func snapshot() -> SystemDefaultInputSnapshot {
        let currentID = access.defaultInputID()
        let currentUID = currentID.flatMap(access.uid)
        let currentName = currentID.flatMap(access.name) ?? "未检测到系统默认输入"
        let remote = access.validatedRemoteInput()
        // Restoration must remain available even if the hidden output or the
        // plug-in catalog is damaged. The current default input's exact UID is
        // sufficient to identify the public endpoint; full endpoint validation
        // remains mandatory before selecting it.
        let remoteIsDefault = currentUID == VoiceAudioCatalog.inputUID
        // A recovery UID only belongs to the uninterrupted period in which the
        // product input remains the default. Once another valid input is seen,
        // it is a new user/application choice and the old recovery record must
        // never become ownership evidence in a later session.
        if let currentUID, currentUID != VoiceAudioCatalog.inputUID {
            storage.previousDefaultInputUID = nil
        }
        var previousName: String?
        var canRestore = false
        if remoteIsDefault, let previousUID = storage.previousDefaultInputUID,
           previousUID != VoiceAudioCatalog.inputUID,
           let previousID = access.translate(uid: previousUID), access.isUsableInput(previousID),
           access.uid(for: previousID) == previousUID {
            previousName = access.name(for: previousID) ?? "原默认输入"
            canRestore = true
        }
        return SystemDefaultInputSnapshot(currentName: currentName, currentUID: currentUID,
            remoteIsDefault: remoteIsDefault,
            canSelectRemote: remote != nil && !remoteIsDefault,
            canRestorePrevious: canRestore, previousName: previousName)
    }

    @discardableResult
    func selectRemoteInput() throws -> SystemDefaultInputSnapshot {
        guard let remote = access.validatedRemoteInput(),
              remote.uid == VoiceAudioCatalog.inputUID,
              access.uid(for: remote.deviceID) == VoiceAudioCatalog.inputUID else {
            throw SystemDefaultInputError.remoteUnavailable
        }
        guard let currentID = access.defaultInputID() else {
            throw SystemDefaultInputError.currentUnavailable
        }
        if currentID == remote.deviceID { return snapshot() }
        guard access.isUsableInput(currentID), let currentUID = access.uid(for: currentID),
              !currentUID.isEmpty, currentUID != VoiceAudioCatalog.inputUID else {
            throw SystemDefaultInputError.currentIdentityUnavailable
        }
        storage.previousDefaultInputUID = currentUID
        switch access.setDefaultInputAndWait(remote.deviceID) {
        case .confirmed:
            break
        case .failed(let status):
            storage.previousDefaultInputUID = nil
            throw status == kAudioHardwareIllegalOperationError
                ? SystemDefaultInputError.propertyNotSettable
                : SystemDefaultInputError.setFailed(status)
        case .confirmationTimedOut:
            // The HAL may still finish an accepted asynchronous request, but
            // without its notification we cannot safely claim ownership of a
            // later remote-default state. Discard automatic recovery evidence.
            storage.previousDefaultInputUID = nil
            throw SystemDefaultInputError.confirmationTimedOut
        }
        guard access.defaultInputID() == remote.deviceID,
              access.uid(for: remote.deviceID) == VoiceAudioCatalog.inputUID else {
            storage.previousDefaultInputUID = nil
            throw SystemDefaultInputError.verificationFailed
        }
        return snapshot()
    }

    @discardableResult
    func restorePreviousInput() throws -> SystemDefaultInputRestoreResult {
        guard let previousUID = storage.previousDefaultInputUID else { return .nothingToRestore }
        guard let currentID = access.defaultInputID() else {
            throw SystemDefaultInputError.currentUnavailable
        }
        guard let currentUID = access.uid(for: currentID) else {
            throw SystemDefaultInputError.currentIdentityUnavailable
        }
        guard currentUID == VoiceAudioCatalog.inputUID else {
            storage.previousDefaultInputUID = nil
            return .currentChanged(access.name(for: currentID) ?? "其他输入")
        }
        guard previousUID != VoiceAudioCatalog.inputUID,
              let previousID = access.translate(uid: previousUID), access.isUsableInput(previousID),
              access.uid(for: previousID) == previousUID else { return .previousUnavailable }
        // Core Audio does not provide compare-and-swap for the default input.
        // This last read narrows the window, while the explicit user action is
        // the authority for the subsequent change; do not describe it as an
        // atomic guard in UI or documentation.
        guard let latestID = access.defaultInputID() else {
            throw SystemDefaultInputError.currentUnavailable
        }
        guard let latestUID = access.uid(for: latestID) else {
            throw SystemDefaultInputError.currentIdentityUnavailable
        }
        guard latestUID == VoiceAudioCatalog.inputUID else {
            storage.previousDefaultInputUID = nil
            return .currentChanged(access.name(for: latestID) ?? "其他输入")
        }
        switch access.setDefaultInputAndWait(previousID) {
        case .confirmed:
            break
        case .failed(let status):
            throw status == kAudioHardwareIllegalOperationError
                ? SystemDefaultInputError.propertyNotSettable
                : SystemDefaultInputError.setFailed(status)
        case .confirmationTimedOut:
            storage.previousDefaultInputUID = nil
            throw SystemDefaultInputError.confirmationTimedOut
        }
        guard access.defaultInputID() == previousID,
              access.uid(for: previousID) == previousUID else {
            storage.previousDefaultInputUID = nil
            throw SystemDefaultInputError.verificationFailed
        }
        let name = access.name(for: previousID) ?? "原默认输入"
        storage.previousDefaultInputUID = nil
        return .restored(name)
    }
}

final class LiveSystemDefaultInputAccess: SystemDefaultInputAccess {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let notificationQueue = DispatchQueue(
        label: "org.rc001remote.assistant.default-input-notification", qos: .userInitiated)

    func validatedRemoteInput() -> VoiceAudioDevice? { VoiceAudioCatalog.inputDevice() }

    func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioDeviceID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &value) == noErr,
              bytes == MemoryLayout<AudioDeviceID>.size, value != kAudioObjectUnknown else { return nil }
        return value
    }

    func uid(for device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    func name(for device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    func translate(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = uid as CFString
        var qualifier = Unmanaged.passUnretained(value)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(value) {
            AudioObjectGetPropertyData(system, &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &bytes, &device)
        }
        guard status == noErr, bytes == MemoryLayout<AudioDeviceID>.size,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    func isUsableInput(_ device: AudioDeviceID) -> Bool {
        scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1
            && scalar(device, kAudioDevicePropertyIsHidden) == 0
            && channels(device, kAudioDevicePropertyScopeInput) > 0
    }

    func setDefaultInputAndWait(_ device: AudioDeviceID) -> SystemDefaultInputMutationResult {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        let query = AudioObjectIsPropertySettable(system, &address, &settable)
        guard query == noErr, settable.boolValue else { return .failed(kAudioHardwareIllegalOperationError) }

        // HAL property changes are asynchronous. Register before writing and do
        // not report success until the listener has fired and a read confirms
        // the requested device. This method runs on the model's background
        // audio-inspection queue; callbacks use a separate queue.
        let notification = DispatchSemaphore(value: 0)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in notification.signal() }
        let addStatus = AudioObjectAddPropertyListenerBlock(system, &address, notificationQueue, listener)
        guard addStatus == noErr else { return .failed(addStatus) }
        var value = device
        let status = AudioObjectSetPropertyData(system, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        var outcome: SystemDefaultInputMutationResult = status == noErr ? .confirmationTimedOut : .failed(status)
        if status == noErr {
            let deadline = DispatchTime.now() + .seconds(2)
            while DispatchTime.now() < deadline,
                  notification.wait(timeout: deadline) == .success {
                if defaultInputID() == device {
                    outcome = .confirmed
                    break
                }
            }
        }
        let removeStatus = AudioObjectRemovePropertyListenerBlock(system, &address, notificationQueue, listener)
        if removeStatus != noErr {
            // CoreAudio retains the registered block; this access object keeps
            // the queue alive for the process lifetime. An exceptional HAL
            // cleanup failure still cannot dereference stack state.
            NSLog("无法移除系统默认输入监听器（%d）", removeStatus)
        }
        return outcome
    }

    private func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value) == noErr,
              bytes == MemoryLayout<Unmanaged<CFString>?>.size, let value else { return nil }
        let text = (value.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func scalar(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &value) == noErr,
              bytes == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private func channels(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        let header = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr,
              Int(bytes) >= header, bytes <= 65_536 else { return 0 }
        let capacity = Int(bytes)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, raw) == noErr,
              Int(bytes) >= header, Int(bytes) <= capacity else { return 0 }
        let announced = Int(raw.load(as: UInt32.self))
        guard announced <= (Int(bytes) - header) / MemoryLayout<AudioBuffer>.stride else { return 0 }
        let buffers = raw.advanced(by: header).assumingMemoryBound(to: AudioBuffer.self)
        return (0..<announced).reduce(0) { $0 + Int(buffers[$1].mNumberChannels) }
    }
}
