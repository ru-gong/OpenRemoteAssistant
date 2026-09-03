// SPDX-License-Identifier: GPL-3.0-only
// ATVV protocol and high-nibble-first IMA decoder adapted from the vendored
// nijez/open-voice-bridge revision 1796b149f752ff2d2fa82fd818f8a5a2bc60802a.
// This is a reusable, explicitly enabled service, not the diagnostic one-shot.
import Foundation
import CoreBluetooth

struct VoiceLevelPublicationGate {
    static let minimumIntervalNanoseconds: UInt64 = 50_000_000 // 20 Hz
    private(set) var lastPublication: UInt64?

    mutating func shouldPublish(now: UInt64) -> Bool {
        if let lastPublication, now >= lastPublication,
           now - lastPublication < Self.minimumIntervalNanoseconds { return false }
        lastPublication = now
        return true
    }

    mutating func reset() { lastPublication = nil }
}

struct RemoteVoiceStatus {
    var isEnabled = false
    var isDiscovering = false
    var isRestarting = false
    var isReady = false
    var isStreaming = false
    var isAudioRouting = false
    var audioFrames = 0
    var audioSamples = 0
    var hasReceivedAudio: Bool { isReady && audioFrames > 0 }
    var audioDeviceUID: String?
    var message = "语音服务未启用。"
}

enum VoiceDecodedFrameRoute: Equatable {
    case direct
    case typeless
    case stop

    static func decide(typelessEnabled: Bool, controllerAccepted: Bool) -> Self {
        guard typelessEnabled else { return .direct }
        return controllerAccepted ? .typeless : .stop
    }
}

enum RC003VoiceProtocol {
    static let serviceUUID = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    static let transmitUUID = "AB5E0002-5A21-4F05-BC7D-AF01F617B664"
    static let audioUUID = "AB5E0003-5A21-4F05-BC7D-AF01F617B664"
    static let controlUUID = "AB5E0004-5A21-4F05-BC7D-AF01F617B664"
    static let getCapabilities = Data([0x0A, 1, 0, 0, 3, 3])
    static let microphoneOpen = Data([0x0C, 0])
    static func microphoneClose(_ session: UInt8) -> Data { Data([0x0D, session]) }
    /// Exact responses observed from the supported RC003-MS sample running
    /// A.7.0.6. Both declare ATVV 1.0, 16 kHz codec 2 and 120-byte ADPCM
    /// frames. The remote has returned both the codec-bitmap fallback layout
    /// and the standard v1 layout across separate connections.
    static let supportedCapabilities: Set<Data> = [
        Data([0x0B, 1, 0, 0, 3, 0, 120, 0, 0]),
        Data([0x0B, 1, 0, 2, 3, 0, 120, 0, 0]),
    ]
    static let sampleRate = 16_000
    static let frameBytes = 120
    static let samplesPerFrame = 240

    static func validCapabilities(_ data: Data) -> Bool {
        data.count == 9 && supportedCapabilities.contains(data)
    }
}

/// Matches the RC003-MS capability probe and the upstream RC003 capture flow:
/// explicitly requested, both notifications must be confirmed before GET_CAPS.
/// Subscription alone never opens the remote microphone or permits PCM routing.
struct RC003VoiceHandshake {
    enum Channel: Hashable { case control, audio }
    let audioEnabled: Bool
    private(set) var confirmed = Set<Channel>()
    private(set) var capabilitiesRequested = false
    var notificationsReady: Bool {
        confirmed.contains(.control) && (!audioEnabled || confirmed.contains(.audio))
    }
    /// Returns true only once, when it is time to send GET_CAPS.
    mutating func confirm(_ channel: Channel) -> Bool {
        guard channel != .audio || audioEnabled else { return false }
        confirmed.insert(channel)
        guard notificationsReady, !capabilitiesRequested else { return false }
        capabilitiesRequested = true
        return true
    }
}

/// Receipt evidence is counted only after a complete frame was successfully
/// enqueued. Zero-valued PCM is still received data. Deadline tokens invalidate
/// old holds and older frames without retaining or logging any PCM samples.
struct RC003AudioReceipt {
    private(set) var frames = 0
    private(set) var samples = 0
    private var token: UInt64 = 0
    private var active = false
    var deadlineToken: UInt64? { active ? token : nil }
    mutating func resetHold() { frames = 0; samples = 0; active = false; token &+= 1 }
    mutating func startStreaming() { active = true; token &+= 1 }
    @discardableResult
    mutating func enqueued(sampleCount: Int) -> Bool {
        guard active, sampleCount > 0 else { return false }
        let first = frames == 0
        frames += 1; samples += sampleCount; token &+= 1
        return first
    }
    mutating func end() { active = false; token &+= 1 }
    func shouldTimeout(_ expected: UInt64) -> Bool { active && token == expected }
}

enum VoiceHoldAction: Equatable {
    case button(Bool), beginHold, openMicrophone, streamStarted, streamEnded
    case closeMicrophone(UInt8), failure(String)
}

/// Pure control state. Every physical release returns to idle, permitting any
/// number of holds. Duplicate START/REQUEST never resets the current decoder.
struct RC003VoiceHold {
    let audioEnabled: Bool
    private(set) var held = false
    private(set) var streaming = false
    private(set) var sessionID: UInt8 = 0
    private(set) var microphoneMayBeOpen = false

    mutating func control(_ data: Data) -> [VoiceHoldAction] {
        let b = Array(data)
        guard !b.isEmpty, b.count <= 64 else { return [.failure("语音控制报告异常。") ] }
        switch b[0] {
        case 0x08:
            guard !held else { return [] }
            held = true
            var result: [VoiceHoldAction] = [.button(true), .beginHold]
            if audioEnabled { microphoneMayBeOpen = true; result.append(.openMicrophone) }
            return result
        case 0x04:
            guard b.count >= 4, b[2] == 2 else {
                microphoneMayBeOpen = true
                if b.count >= 4 { sessionID = b[3] }
                return [.failure("遥控器语音编码或会话标识异常。")]
            }
            if streaming { return b[3] == sessionID ? [] : [.failure("语音会话在按住期间改变。") ] }
            var result: [VoiceHoldAction] = []
            if !held { held = true; result += [.button(true), .beginHold] }
            sessionID = b[3]
            microphoneMayBeOpen = true // A physical press can start the remote itself.
            streaming = true
            if audioEnabled { result.append(.streamStarted) }
            return result
        case 0x00:
            guard held || microphoneMayBeOpen else { return [] }
            let close = microphoneMayBeOpen
            let oldSession = sessionID
            held = false; streaming = false; microphoneMayBeOpen = false; sessionID = 0
            var result: [VoiceHoldAction] = [.button(false), .streamEnded]
            if close { result.append(.closeMicrophone(oldSession)) }
            return result
        default: return []
        }
    }
}

/// One hold's bounded decoder, with no radio, CoreAudio, filesystem or logger.
/// Replaced on each new hold; partial frames are discarded on release or sync.
final class RC003VoicePCM {
    enum Failure: Error { case invalidPacket, invalidSync, sampleCountOverflow }
    private let decoder = VoiceIMAADPCMDecoder()
    private var pending: [UInt8] = []
    private var pendingSync: (Int, Int)?
    private(set) var sampleCount = 0

    func synchronize(_ data: Data) throws {
        let b = Array(data)
        guard b.count >= 7, b.count <= 64, b[0] == 0x0A, b[6] <= 88 else { throw Failure.invalidSync }
        pending.removeAll(keepingCapacity: false)
        pendingSync = (Int(Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5]))), Int(b[6]))
    }

    func decode(_ data: Data) throws -> [[Int16]] {
        guard data.count <= 4_096 else { throw Failure.invalidPacket }
        pending.append(contentsOf: data)
        var frames: [[Int16]] = []
        var offset = 0
        while pending.count - offset >= RC003VoiceProtocol.frameBytes {
            if let sync = pendingSync { decoder.reset(sync.0, sync.1); pendingSync = nil }
            let (nextSampleCount, overflow) = sampleCount.addingReportingOverflow(
                RC003VoiceProtocol.samplesPerFrame)
            guard !overflow else { throw Failure.sampleCountOverflow }
            frames.append(decoder.decode(pending[offset..<(offset + RC003VoiceProtocol.frameBytes)]))
            sampleCount = nextSampleCount; offset += RC003VoiceProtocol.frameBytes
        }
        if offset > 0 { pending = Array(pending.dropFirst(offset)) }
        return frames
    }
}

final class VoiceIMAADPCMDecoder {
    private static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,
        97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
        1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,
        5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,
        27086,29794,32767]
    private static let indices = [-1,-1,-1,-1,2,4,6,8]
    private var predictor = 0
    private var stepIndex = 0
    func reset(_ value: Int = 0, _ index: Int = 0) {
        predictor = min(32_767, max(-32_768, value)); stepIndex = min(88, max(0, index))
    }
    func decode<S: Sequence>(_ bytes: S) -> [Int16] where S.Element == UInt8 {
        var result: [Int16] = []
        for byte in bytes { result.append(nibble(Int(byte >> 4))); result.append(nibble(Int(byte & 15))) }
        return result
    }
    private func nibble(_ value: Int) -> Int16 {
        let step = Self.steps[stepIndex]
        var delta = step >> 3
        if value & 1 != 0 { delta += step >> 2 }
        if value & 2 != 0 { delta += step >> 1 }
        if value & 4 != 0 { delta += step }
        predictor = min(32_767, max(-32_768, predictor + (value & 8 != 0 ? -delta : delta)))
        stepIndex = min(88, max(0, stepIndex + Self.indices[value & 7]))
        return Int16(predictor)
    }
}

/// Main-thread only. Construction is inert. Explicit enable creates a BLE
/// central; only the sole already-connected, identity-verified RC003-MS is eligible. No scan,
/// pairing, automatic reconnect, key injection, on-disk recording or mic input.
final class RemoteVoiceService: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((RemoteVoiceStatus) -> Void)?
    /// One final callback per explicit discovery, including cancellation/failure.
    var onDiscovery: (([RemoteDeviceCandidate], String) -> Void)?
    var onVoiceButton: ((Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onVoiceShortcutFailure: ((VoiceFnTapFailure) -> Void)?
    var validateVoiceShortcutBeforeActivation: (() -> Bool)?
    private(set) var status = RemoteVoiceStatus()
    private(set) var voiceShortcutBehavior: VoiceShortcutBehavior = .off
    static func availableAudioDevices() -> [VoiceAudioDevice] { VoiceAudioCatalog.devices() }

    private struct Configuration {
        let buttonEvents: Bool
        let audioDeviceUID: String?
        let binding: DeviceBinding?
        var isDiscovery: Bool { binding == nil }
    }
    private enum Phase { case idle, connecting, handshaking, ready, stopping }
    private var phase = Phase.idle
    private var configuration: Configuration?
    private var targetBinding: DeviceBinding?
    private var discoveryCandidates: [RemoteDeviceCandidate] = []
    private var discoveryReplyPending = false
    private var identityValues: [String: String] = [:]
    private var pnpIdentity: RemoteDevicePnPIdentity?
    private var verifiedIdentity: RemoteDeviceIdentity?
    private var restart: Configuration?
    private var completionHandlers: [() -> Void] = []
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var control: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var modelValidated = false
    private var capsValidated = false
    private var controlRequested = false
    private var audioRequested = false
    private var handshake: RC003VoiceHandshake?
    private var connectionAttempted = false
    private var responseQueue: [Bool] = []
    private var hold: RC003VoiceHold?
    private var pcm: RC003VoicePCM?
    private var audioReceipt = RC003AudioReceipt()
    private var earlyAudio = Data()
    private var output = VoiceAudioOutput()
    private lazy var voiceFnTapSession = VoiceFnTapSessionController(
        setFunctionKeyPressed: { MacFunctionKeyInjector.setPressed($0) },
        enqueueAudio: { [weak self] samples in self?.enqueueDecodedFrame(samples) },
        drainAudio: { [weak self] completion in
            guard let self else { completion(); return }
            // A very short press can end before the opening Fn tap finishes.
            // Keep the receipt active until the controller has flushed pre-roll;
            // otherwise real queued samples would be omitted from status.
            self.audioDeadline?.cancel()
            self.audioDeadline = nil
            self.audioReceipt.end()
            self.output.finishAfterDraining(completion: completion)
        },
        onFailure: { [weak self] failure in
            // Avoid mutating controller configuration from inside its own
            // failure transition. Fail closed before the model restores the
            // physical HID mapping: audio must never fall through to the plain
            // route after an opening/closing Fn tap failed.
            DispatchQueue.main.async {
                guard let self else { return }
                let stage = failure.stageDescription
                // Keep physical F5 neutralized until BLE close/disconnect and
                // audio teardown have converged. Only then may the model restore
                // the mapping and update the compatibility preference.
                self.completionHandlers.append { [weak self] in
                    self?.onVoiceShortcutFailure?(failure)
                }
                self.stop("语音快捷键 Fn \(stage)失败；已立即关麦并停止音频。")
            }
        }
    )
    private lazy var voiceFnHoldSession = VoiceFnHoldSessionController(
        setFunctionKeyPressed: { MacFunctionKeyInjector.setPressed($0) },
        drainAudio: { [weak self] completion in
            guard let self else { completion(); return }
            self.audioDeadline?.cancel()
            self.audioDeadline = nil
            self.audioReceipt.end()
            self.output.finishAfterDraining(completion: completion)
        },
        onFailure: { [weak self] failure in
            DispatchQueue.main.async {
                guard let self else { return }
                self.completionHandlers.append { [weak self] in
                    self?.onVoiceShortcutFailure?(failure)
                }
                self.stop("语音快捷键 Fn \(failure.stageDescription)失败；已立即关麦并停止音频。")
            }
        }
    )
    private var levelPublicationGate = VoiceLevelPublicationGate()
    private var initializationDeadline: DispatchWorkItem?
    private var startDeadline: DispatchWorkItem?
    private var audioDeadline: DispatchWorkItem?
    private var closeDeadline: DispatchWorkItem?
    private var pendingClose: Data?
    private var generation: UInt64 = 0
    private var stopMessage = "语音服务未启用。"

    private let serviceID = CBUUID(string: RC003VoiceProtocol.serviceUUID)
    private let transmitID = CBUUID(string: RC003VoiceProtocol.transmitUUID)
    private let controlID = CBUUID(string: RC003VoiceProtocol.controlUUID)
    private let audioID = CBUUID(string: RC003VoiceProtocol.audioUUID)
    private let informationID = CBUUID(string: "180A")
    private let identityTextIDs = ["2A29", "2A24", "2A27", "2A26", "2A28"].map(CBUUID.init(string:))
    private let pnpID = CBUUID(string: "2A50")
    private var identityIDs: [CBUUID] { identityTextIDs + [pnpID] }

    func configureTarget(_ binding: DeviceBinding?) {
        precondition(Thread.isMainThread)
        guard targetBinding != binding else { return }
        disable()
        targetBinding = binding?.isValid == true ? binding : nil
    }

    /// Configures one explicit software-Fn interaction. Toggle mode uses two
    /// short taps; hold mode presses before MIC_OPEN and releases after tail
    /// audio drains. Both paths are balanced on stop and shutdown.
    func setVoiceShortcutBehavior(_ behavior: VoiceShortcutBehavior, completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard behavior != voiceShortcutBehavior else { completion?(); return }
        let previous = voiceShortcutBehavior
        voiceShortcutBehavior = behavior
        let activate = { [weak self] in
            guard let self else { completion?(); return }
            switch behavior {
            case .off:
                completion?()
            case .toggleFunction:
                self.voiceFnTapSession.resume()
                self.voiceFnTapSession.setEnabled(true, completion: completion)
            case .holdFunction:
                self.voiceFnHoldSession.resume()
                self.voiceFnHoldSession.setEnabled(true, completion: completion)
            }
        }
        switch previous {
        case .off: activate()
        case .toggleFunction: voiceFnTapSession.setEnabled(false, completion: activate)
        case .holdFunction: voiceFnHoldSession.setEnabled(false, completion: activate)
        }
    }

    /// User-initiated only. This does not scan/pair and never subscribes audio or
    /// sends MIC_OPEN. A physical premature START is closed and discovery fails.
    func discoverConnectedDevices() {
        precondition(Thread.isMainThread)
        guard !discoveryReplyPending else { return }
        discoveryReplyPending = true
        let requested = Configuration(buttonEvents: false, audioDeviceUID: nil, binding: nil)
        if phase != .idle {
            restart = requested
            stop("正在停止旧会话以查询已连接遥控器。")
        } else { begin(requested) }
    }

    func enable(buttonEvents: Bool, audioDeviceUID: String? = nil) {
        precondition(Thread.isMainThread)
        guard buttonEvents || audioDeviceUID != nil else { disable(); return }
        guard let binding = targetBinding, binding.isValid else {
            publish("请先显式查询并确认本机遥控器绑定；未连接设备。")
            return
        }
        let requested = Configuration(buttonEvents: buttonEvents, audioDeviceUID: audioDeviceUID, binding: binding)
        if restart?.isDiscovery == true, configuration?.isDiscovery != true {
            completeDiscovery([], message: "查询已取消，尚未连接查询目标。")
        }
        if phase != .idle {
            restart = requested
            stop("正在安全重启语音服务。")
        } else { begin(requested) }
    }

    func disable(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        restart = nil
        if discoveryReplyPending, configuration?.isDiscovery != true {
            completeDiscovery([], message: "查询已取消，尚未连接查询目标。")
        }
        if let completion { completionHandlers.append(completion) }
        stop("语音服务已停止；未保存音频。")
    }

    private func begin(_ requested: Configuration) {
        guard phase == .idle else { return }
        if requested.isDiscovery, !discoveryReplyPending { return }
        guard CBCentralManager.authorization != .denied && CBCentralManager.authorization != .restricted else {
            let message = "蓝牙权限未授权；请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用。"
            publish(message)
            if requested.isDiscovery { completeDiscovery([], message: message) }
            return
        }
        if let uid = requested.audioDeviceUID,
           VoiceAudioCatalog.devices().filter({ $0.uid == uid }).count != 1 {
            publish("需安装并选择遥控器麦克风组件；未连接遥控器、未启用音频。")
            return
        }
        generation &+= 1
        if voiceShortcutBehavior == .toggleFunction {
            voiceFnTapSession.resume()
            voiceFnTapSession.setEnabled(true)
        } else if voiceShortcutBehavior == .holdFunction {
            voiceFnHoldSession.resume()
            voiceFnHoldSession.setEnabled(true)
        }
        audioReceipt.resetHold()
        configuration = requested
        discoveryCandidates = []
        identityValues = [:]
        pnpIdentity = nil
        verifiedIdentity = nil
        handshake = RC003VoiceHandshake(audioEnabled: requested.audioDeviceUID != nil)
        phase = .connecting
        output.onFailure = { [weak self] message in self?.stop(message) }
        publish(requested.isDiscovery ? "正在查询已连接遥控器的型号、版本和能力；不接收声音。" : "正在验证已确认绑定的遥控器；等待新的物理按键。")
        arm(&initializationDeadline, seconds: 15) { [weak self] in self?.stop("语音服务初始化超时；未启动音频，请检查蓝牙权限并重试。") }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, phase != .idle, phase != .stopping else { return }
        switch central.state {
        case .unknown, .resetting: return
        case .unauthorized: stop("蓝牙权限未授权；请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用。"); return
        case .poweredOff: stop("蓝牙已关闭；语音服务未启用。"); return
        case .unsupported: stop("当前 Mac 不支持所需蓝牙服务。"); return
        case .poweredOn: break
        @unknown default: stop("蓝牙状态不可用。"); return
        }
        guard !connectionAttempted else { return }
        connectionAttempted = true
        // Only the exact ATVV service is eligible. No broad HID-service fallback
        // that would connect an unrelated keyboard, and no name-based identity.
        let matches = central.retrieveConnectedPeripherals(withServices: [serviceID])
        do {
            let selectedID = try RemoteDiscoveryPolicy.select(matches.map(\.identifier),
                boundIdentifier: configuration?.binding?.bleIdentifier)
            guard let selected = matches.first(where: { $0.identifier == selectedID }) else { throw DeviceSelectionError.missing }
            peripheral = selected
            selected.delegate = self
            central.connect(selected, options: nil)
        } catch { stop(error.localizedDescription) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, current(peripheral) else { return }
        phase = .handshaking
        peripheral.discoverServices([informationID, serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, current(peripheral) else { return }
        stop("RC003-MS 语音连接失败；请确认遥控器在线后手动重试。")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, self.peripheral === peripheral else { return }
        if phase == .stopping { finishStop() } else { stop("遥控器已断开；语音服务已停止，重连后需手动启用。") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard current(peripheral) else { return }
        let services = peripheral.services ?? []
        guard error == nil, services.filter({ $0.uuid == informationID }).count == 1,
              services.filter({ $0.uuid == serviceID }).count == 1 else { stop("遥控器缺少唯一的设备信息或 ATVV 语音服务。"); return }
        for service in services {
            if service.uuid == informationID { peripheral.discoverCharacteristics(identityIDs, for: service) }
            if service.uuid == serviceID { peripheral.discoverCharacteristics([transmitID, controlID, audioID], for: service) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard current(peripheral) else { return }
        guard error == nil else { stop("无法读取遥控器语音特征。"); return }
        let all = service.characteristics ?? []
        func unique(_ id: CBUUID) -> CBCharacteristic? {
            let matches = all.filter { $0.uuid == id }; return matches.count == 1 ? matches[0] : nil
        }
        if service.uuid == informationID {
            let characteristics = identityIDs.compactMap(unique)
            guard characteristics.count == identityIDs.count, characteristics.allSatisfy({ $0.properties.contains(.read) }) else {
                stop("设备缺少可读取的型号/硬件/固件/软件信息，无法验证支持组合。"); return
            }
            for characteristic in characteristics { peripheral.readValue(for: characteristic) }
        } else if service.uuid == serviceID {
            guard let tx = unique(transmitID), let ctrl = unique(controlID), let voice = unique(audioID),
                  tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse),
                  ctrl.properties.contains(.notify) || ctrl.properties.contains(.indicate),
                  voice.properties.contains(.notify) || voice.properties.contains(.indicate) else {
                stop("遥控器语音特征或权限不符合 RC003-MS 协议。"); return
            }
            transmit = tx; control = ctrl; audio = voice
        }
        subscribeIfPossible()
    }

    private func subscribeIfPossible() {
        guard phase == .handshaking, modelValidated, !controlRequested,
              let peripheral, let control, transmit != nil, let audio else { return }
        // Follow the RC003-MS capability probe and upstream RC003 order:
        // subscribe both channels, then GET_CAPS. Audio subscription is permitted
        // only after an explicit output selection; all bytes are discarded until
        // caps pass and a later physical voice-button trigger starts a hold.
        controlRequested = true
        peripheral.setNotifyValue(true, for: control)
        if configuration?.audioDeviceUID != nil {
            audioRequested = true
            peripheral.setNotifyValue(true, for: audio)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard current(peripheral) else { return }
        let channel: RC003VoiceHandshake.Channel
        if characteristic.uuid == controlID, controlRequested { channel = .control }
        else if characteristic.uuid == audioID, audioRequested { channel = .audio }
        else { return }
        guard error == nil, characteristic.isNotifying else { stop("语音通知订阅失败；服务已停止。"); return }
        guard var handshake else { return }
        let requestCapabilities = handshake.confirm(channel)
        self.handshake = handshake
        if requestCapabilities {
            guard write(RC003VoiceProtocol.getCapabilities) else { stop("无法请求遥控器语音能力。"); return }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard current(peripheral) else { return }
        guard error == nil, let data = characteristic.value else { stop("读取语音服务失败；已停止。"); return }
        if characteristic.uuid == pnpID {
            guard let parsed = RemoteDevicePnPIdentity.parse(data) else {
                stop("遥控器 PnP 身份信息格式异常；未启用服务。"); return
            }
            pnpIdentity = parsed
            validateIdentityIfComplete(peripheral)
            return
        }
        if identityTextIDs.contains(characteristic.uuid) {
            guard data.count <= 256, let text = String(data: data, encoding: .utf8) else {
                stop("遥控器身份信息格式异常；未启用服务。"); return
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !value.isEmpty else { stop("遥控器身份信息为空；未启用服务。"); return }
            identityValues[characteristic.uuid.uuidString] = value
            validateIdentityIfComplete(peripheral)
            return
        }
        if characteristic.uuid == controlID {
            if data.first == 0x0B {
                guard modelValidated, handshake?.capabilitiesRequested == true,
                      RC003VoiceProtocol.validCapabilities(data) else {
                    stop("遥控器未通过 16 kHz / 120 字节帧语音能力校验。"); return
                }
                if capsValidated { return }
                capsValidated = true
                becomeReady()
                return
            }
            guard phase == .ready else {
                // A physical press can make RC003 start itself while setup is
                // unfinished. Do not accept its audio or bind a key; retain only
                // the close session ID and request shutdown immediately.
                if data.first == 0x04 {
                    var premature = RC003VoiceHold(audioEnabled: false)
                    _ = premature.control(data)
                    hold = premature
                    stop("遥控器在初始化完成前开始语音；已请求关麦，请就绪后再按语音键。")
                }
                return
            }
            if data.first == 0x0A, configuration?.audioDeviceUID != nil, hold?.held == true {
                do { try pcm?.synchronize(data); earlyAudio = Data() }
                catch { stop("语音同步参数异常；已停止推流。") }
                return
            }
            guard var hold else { return }
            let actions = hold.control(data)
            self.hold = hold
            handle(actions)
        } else if characteristic.uuid == audioID {
            guard phase == .ready, configuration?.audioDeviceUID != nil, hold?.held == true else { return }
            if hold?.streaming == true { decodeAndRoute(data) }
            else {
                guard data.count <= 4_096, earlyAudio.count + data.count <= 1_920 else { stop("语音开始前缓冲异常；已停止。"); return }
                earlyAudio.append(data)
            }
        }
    }

    private func becomeReady() {
        guard phase == .handshaking, capsValidated, handshake?.notificationsReady == true,
              let configuration else { return }
        if configuration.isDiscovery {
            guard let peripheral, let identity = verifiedIdentity else { stop("设备身份验证不完整。"); return }
            discoveryCandidates = [RemoteDeviceCandidate(identifier: peripheral.identifier,
                name: peripheral.name ?? "小米蓝牙语音遥控器", identity: identity, profileID: DeviceProfile.rc003MS.id)]
            stop("发现一个支持的 RC003-MS（设备自报 RC003）；请确认只连接了这一只且是手中的设备，再保存本机绑定。")
            return
        }
        phase = .ready
        initializationDeadline?.cancel(); initializationDeadline = nil
        hold = RC003VoiceHold(audioEnabled: configuration.audioDeviceUID != nil)
        publish(configuration.audioDeviceUID == nil
            ? "语音键监听已就绪；不订阅音频、不发送开麦命令。"
            : "遥控器已连接；按住语音键开始接收音频，松手停止；不设固定录音时长。")
    }

    private func handle(_ actions: [VoiceHoldAction]) {
        for action in actions {
            guard phase == .ready else { return }
            switch action {
            case .button(let down):
                if configuration?.buttonEvents == true { onVoiceButton?(down) }
                if down, voiceShortcutBehavior != .off {
                    guard validateVoiceShortcutBeforeActivation?() == true else {
                        stop("语音快捷键未能重新确认遥控器物理 F5 已中和；已立即关麦，未发送 Fn 或声音。")
                        return
                    }
                    if voiceShortcutBehavior == .holdFunction,
                       !voiceFnHoldSession.startVoice() {
                        stop("Fn 长按会话未就绪；未发送声音，请重新选择语音软件预设。")
                        return
                    }
                }
            case .beginHold:
                pcm = RC003VoicePCM(); earlyAudio = Data()
                audioReceipt.resetHold()
                levelPublicationGate.reset()
                publish(configuration?.audioDeviceUID == nil ? "语音键已按下。" : "语音键已按下，等待遥控器开麦。")
            case .openMicrophone:
                guard prepareOutput(), write(RC003VoiceProtocol.microphoneOpen) else { stop("无法准备虚拟音频或发送开麦命令；已停止。"); return }
                arm(&startDeadline, seconds: 2) { [weak self] in self?.stop("遥控器未确认语音开始；已请求关麦并停止服务。") }
            case .streamStarted:
                startDeadline?.cancel(); startDeadline = nil
                // REQUEST already prepared it; direct START must prepare here.
                if !status.isAudioRouting, !prepareOutput() { return }
                audioReceipt.startStreaming()
                armAudioDeadline()
                if voiceShortcutBehavior == .toggleFunction {
                    guard voiceFnTapSession.startVoice() else {
                        stop("Fn 点按会话未就绪；未发送声音，请重新选择语音软件预设。")
                        return
                    }
                }
                publish("遥控器已开麦，等待音频数据；松开后最多 0.75 秒送完已入队尾音。")
                let early = earlyAudio; earlyAudio = Data()
                if !early.isEmpty { decodeAndRoute(early) }
            case .streamEnded:
                startDeadline?.cancel(); startDeadline = nil
                pcm = nil; earlyAudio = Data()
                let handledByShortcut: Bool
                switch voiceShortcutBehavior {
                case .toggleFunction: handledByShortcut = voiceFnTapSession.stopVoice()
                case .holdFunction: handledByShortcut = voiceFnHoldSession.stopVoice()
                case .off: handledByShortcut = false
                }
                if !handledByShortcut {
                    audioDeadline?.cancel(); audioDeadline = nil
                    audioReceipt.end()
                    output.finishAfterDraining()
                }
                levelPublicationGate.reset(); onLevel?(0)
                status.isAudioRouting = false
                publish(configuration?.audioDeviceUID == nil ? "语音键已释放；等待下次按键。" : "遥控器已关麦；已入队尾音会在后台送完（最长 0.75 秒）。")
            case .closeMicrophone(let session):
                // Only teardown's own CLOSE is tagged final, so an older hold's
                // delayed acknowledgement cannot prematurely end teardown.
                guard write(RC003VoiceProtocol.microphoneClose(session)) else { stop("无法确认语音关闭命令已提交；服务已停止。"); return }
            case .failure(let message): stop(message)
            }
        }
    }

    private func prepareOutput() -> Bool {
        guard let uid = configuration?.audioDeviceUID else { return false }
        if let message = output.start(deviceUID: uid) { stop(message); return false }
        status.isAudioRouting = true
        return true
    }

    private func decodeAndRoute(_ data: Data) {
        guard phase == .ready, configuration?.audioDeviceUID != nil, hold?.streaming == true, let pcm else { return }
        do {
            let frames = try pcm.decode(data)
            for frame in frames {
                let controllerAccepted = voiceShortcutBehavior == .toggleFunction
                    ? voiceFnTapSession.receive(frame)
                    : false
                switch VoiceDecodedFrameRoute.decide(
                    typelessEnabled: voiceShortcutBehavior == .toggleFunction,
                    controllerAccepted: controllerAccepted
                ) {
                case .typeless:
                    continue
                case .stop:
                    stop("Fn 点按会话已停止；未将声音回落到普通路径。")
                    return
                case .direct:
                    enqueueDecodedFrame(frame)
                    guard phase == .ready else { return }
                }
            }
        } catch { stop("语音数据异常或采样计数溢出；已停止服务。") }
    }

    private func enqueueDecodedFrame(_ frame: [Int16]) {
        guard phase == .ready, configuration?.audioDeviceUID != nil else { return }
        guard output.enqueue(frame) else {
            stop("\(output.lastEnqueueFailureMessage ?? "虚拟音频输出失败。") 已停止，不回退到扬声器。")
            return
        }
        let first = audioReceipt.enqueued(sampleCount: frame.count)
        status.audioFrames = audioReceipt.frames; status.audioSamples = audioReceipt.samples
        armAudioDeadline()
        if first {
            switch voiceShortcutBehavior {
            case .toggleFunction:
                publish("目标软件已收到开始 Fn 点按；遥控器音频正在送入，松开后排空尾音再点按结束。")
            case .holdFunction:
                publish("目标软件已收到 Fn 按下；遥控器音频正在送入，松开后排空尾音再释放 Fn。")
            case .off:
                publish("已收到遥控器音频并送入“遥控器麦克风”组件；目标软件仍需选择该输入，松开语音键停止。")
            }
        }
        if levelPublicationGate.shouldPublish(now: DispatchTime.now().uptimeNanoseconds) {
            let square = frame.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) }
            onLevel?(min(1, sqrt(square / Double(frame.count))))
        }
    }

    private func armAudioDeadline() {
        guard let token = audioReceipt.deadlineToken else { return }
        arm(&audioDeadline, seconds: 2) { [weak self] in
            guard let self, self.phase == .ready, self.hold?.streaming == true,
                  self.audioReceipt.shouldTimeout(token) else { return }
            self.stop(self.audioReceipt.frames == 0
                ? "遥控器已开麦，但 2 秒内未收到完整音频数据；已请求关麦并停止服务，请重新连接后重试。"
                : "连续 2 秒未收到新的完整音频数据；已请求关麦并停止服务，请重新连接后重试。")
        }
    }

    @discardableResult
    private func write(_ data: Data, isClose: Bool = false) -> Bool {
        guard let peripheral, peripheral.state == .connected, let transmit else { return false }
        if transmit.properties.contains(.write) {
            responseQueue.append(isClose)
            peripheral.writeValue(data, for: transmit, type: .withResponse)
            return true
        }
        guard transmit.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse else { return false }
        peripheral.writeValue(data, for: transmit, type: .withoutResponse)
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == transmitID else { return }
        let wasClose = responseQueue.isEmpty ? false : responseQueue.removeFirst()
        if phase == .stopping {
            if wasClose { if error != nil { stopMessage += " 关麦写入未确认。" }; finishStop() }
        } else if error != nil { stop("语音命令写入失败；已停止服务。") }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, phase == .stopping, let pendingClose else { return }
        if write(pendingClose, isClose: true) { self.pendingClose = nil }
    }

    private func current(_ value: CBPeripheral) -> Bool {
        peripheral === value && phase != .idle && phase != .stopping
    }

    private func validateIdentityIfComplete(_ peripheral: CBPeripheral) {
        guard phase == .handshaking, identityValues.count == identityTextIDs.count,
              let pnpIdentity, !modelValidated else { return }
        let identity = RemoteDeviceIdentity(manufacturer: identityValues["2A29"] ?? "",
            model: identityValues["2A24"] ?? "", hardware: identityValues["2A27"] ?? "",
            firmware: identityValues["2A26"] ?? "", software: identityValues["2A28"] ?? "",
            pnp: pnpIdentity)
        guard DeviceProfile.rc003MS.accepts(identity),
              configuration?.binding.map({ $0.identity == identity && $0.bleIdentifier == peripheral.identifier }) ?? true else {
            stop("遥控器型号、版本或 PnP 身份未通过 RC003-MS 支持列表；未启用服务。")
            return
        }
        verifiedIdentity = identity
        modelValidated = true
        subscribeIfPossible()
    }

    private func stop(_ message: String) {
        if phase == .stopping { return }
        stopMessage = message
        if phase == .idle { publish(message); completeHandlers(); return }
        phase = .stopping
        initializationDeadline?.cancel(); startDeadline?.cancel()
        audioDeadline?.cancel(); audioDeadline = nil; audioReceipt.end()
        // Always converge the controller before disposing retiring audio
        // queues. A compatibility-disable request may already have cleared the
        // local flag while its closing tap is still waiting for the drain
        // completion; conditional cleanup would strand that completion and
        // leave the physical F5 mapping unrestored.
        voiceFnTapSession.shutdown()
        voiceFnHoldSession.shutdown()
        output.stop(); levelPublicationGate.reset(); onLevel?(0)
        if hold?.held == true, configuration?.buttonEvents == true { onVoiceButton?(false) }
        let needsClose = hold?.microphoneMayBeOpen == true
        let session = hold?.sessionID ?? 0
        hold = nil; pcm = nil; earlyAudio = Data()
        status.isAudioRouting = false
        publish(message)
        if needsClose {
            let command = RC003VoiceProtocol.microphoneClose(session)
            if !write(command, isClose: true) { pendingClose = command }
            arm(&closeDeadline, seconds: 0.35) { [weak self] in self?.finishStop() }
        } else { finishStop() }
    }

    private func finishStop() {
        guard phase == .stopping else { return }
        let wasDiscovery = configuration?.isDiscovery == true
        let discovered = discoveryCandidates
        closeDeadline?.cancel(); closeDeadline = nil
        if let peripheral {
            if let audio, audio.isNotifying { peripheral.setNotifyValue(false, for: audio) }
            if let control, control.isNotifying { peripheral.setNotifyValue(false, for: control) }
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.delegate = nil
        peripheral = nil; central = nil; transmit = nil; control = nil; audio = nil
        hold = nil; pcm = nil; configuration = nil; pendingClose = nil; responseQueue.removeAll()
        modelValidated = false; capsValidated = false; controlRequested = false; audioRequested = false
        handshake = nil; connectionAttempted = false
        identityValues = [:]; pnpIdentity = nil; verifiedIdentity = nil; discoveryCandidates = []
        phase = .idle
        generation &+= 1
        publish(stopMessage)
        let next = restart; restart = nil
        if wasDiscovery { completeDiscovery(discovered, message: stopMessage) }
        completeHandlers()
        if let next { begin(next) }
    }

    private func completeHandlers() {
        let callbacks = completionHandlers; completionHandlers.removeAll()
        for callback in callbacks { callback() }
    }
    private func completeDiscovery(_ candidates: [RemoteDeviceCandidate], message: String) {
        guard discoveryReplyPending else { return }
        discoveryReplyPending = false
        onDiscovery?(candidates, message)
    }
    private func arm(_ work: inout DispatchWorkItem?, seconds: Double, action: @escaping () -> Void) {
        work?.cancel()
        let token = generation
        let item = DispatchWorkItem { [weak self] in guard self?.generation == token else { return }; action() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
    private func publish(_ message: String) {
        let active = phase == .connecting || phase == .handshaking || phase == .ready
        status.isDiscovering = configuration?.isDiscovery == true && active
        status.isEnabled = configuration?.isDiscovery == false && active
        status.isRestarting = restart != nil
        status.isReady = phase == .ready
        status.isStreaming = phase == .ready && hold?.streaming == true && configuration?.audioDeviceUID != nil
        status.audioDeviceUID = configuration?.audioDeviceUID
        status.audioFrames = audioReceipt.frames
        status.audioSamples = audioReceipt.samples
        status.message = message
        onStatus?(status)
    }
}
