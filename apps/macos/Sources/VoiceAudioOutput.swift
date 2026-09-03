// SPDX-License-Identifier: GPL-3.0-only
// BlackHole identity/routing references: https://github.com/ExistentialAudio/BlackHole
// Modified 2026-08-31: dedicated input/hidden-output identities and owner checks.
// This file opens only an explicitly selected known loopback output. It never
// creates a virtual device, opens a microphone, or changes system default audio.
import Foundation
import CoreAudio
import AudioToolbox

struct VoiceAudioDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    var id: String { uid }
    let deviceID: AudioDeviceID
}

struct VoiceEndpointIdentity {
    let uid: String
    let name: String
    let manufacturer: String
    let pluginBundleID: String
    let transport: UInt32
    let inputChannels: Int
    let outputChannels: Int
    let isAlive: Bool
}

enum VoiceAudioCatalogCompatibility: Equatable {
    case current
    case previousVirtualInput
    case invalid
}

struct VoiceAudioCatalogSnapshot {
    let compatibility: VoiceAudioCatalogCompatibility
    let input: AudioDeviceID
    let output: AudioDeviceID
}

/// HAL devices may be owned by the AudioSystem object even when supplied by a
/// third-party plug-in. Resolve the plug-in independently, then require both
/// its UID translations to equal the system's selected endpoint objects.
struct VoiceAudioProvider {
    let pluginID: AudioObjectID
    let classID: AudioClassID
    let bundleID: String
    let inputDeviceID: AudioDeviceID
    let outputDeviceID: AudioDeviceID
    func matches(input: AudioDeviceID, output: AudioDeviceID) -> Bool {
        pluginID != kAudioObjectUnknown && pluginID != kAudioObjectSystemObject
            && classID == kAudioPlugInClassID && bundleID == VoiceAudioCatalog.pluginBundleID
            && input != kAudioObjectUnknown && output != kAudioObjectUnknown && input != output
            && inputDeviceID == input && outputDeviceID == output
    }
}

enum VoiceAudioBufferLayout {
    static func validatedDeviceCount(status: OSStatus, byteCount: Int, capacity: Int) -> Int? {
        let stride = MemoryLayout<AudioDeviceID>.stride
        guard status == noErr, byteCount >= 0, byteCount <= capacity, byteCount % stride == 0 else { return nil }
        return byteCount / stride
    }
    static func validatedBufferCount(status: OSStatus, byteCount: Int, capacity: Int, announced: UInt32) -> Int? {
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard status == noErr, byteCount >= header, byteCount <= capacity,
              Int(announced) <= (byteCount - header) / MemoryLayout<AudioBuffer>.stride else { return nil }
        return Int(announced)
    }
}

/// Bounds active plus asynchronously-retiring AudioQueue instances. A normal
/// hold uses one slot; one overlap is allowed while the previous hold is being
/// disposed. If CoreAudio teardown ever stalls, later holds fail closed rather
/// than accumulating queues without limit.
struct VoiceAudioQueueBudget {
    let limit: Int
    private(set) var count = 0
    var canCreate: Bool { limit > 0 && count < limit }
    mutating func didCreate() -> Bool {
        guard canCreate else { return false }
        count += 1
        return true
    }
    mutating func didDispose() {
        if count > 0 { count -= 1 }
    }
}

/// Plans one logical PCM delivery across fixed-size stereo AudioQueue buffers.
/// Typeless deliberately holds a few hundred milliseconds of mono pre-roll
/// until its opening Fn tap completes, so one delivery can be much larger than
/// one AudioQueue buffer even though each BLE frame is small.
enum VoiceAudioChunkPlan {
    static func ranges(sampleCount: Int, samplesPerBuffer: Int,
                       availableBuffers: Int) -> [Range<Int>]? {
        guard sampleCount >= 0, samplesPerBuffer > 0, availableBuffers >= 0 else { return nil }
        guard sampleCount > 0 else { return [] }
        let required = (sampleCount - 1) / samplesPerBuffer + 1
        guard required <= availableBuffers else { return nil }
        return (0..<required).map { index in
            let start = index * samplesPerBuffer
            return start..<min(sampleCount, start + samplesPerBuffer)
        }
    }

    static func requiredBufferCount(sampleCount: Int, samplesPerBuffer: Int) -> Int? {
        guard sampleCount >= 0, samplesPerBuffer > 0 else { return nil }
        return sampleCount == 0 ? 0 : (sampleCount - 1) / samplesPerBuffer + 1
    }
}

enum VoiceAudioDrainDecision: Equatable {
    case wait
    case drained
    case forceRetire
}

enum VoiceAudioDrainPolicy {
    static let timeoutNanoseconds: UInt64 = 750_000_000

    static func decision(isRunning: UInt32?, now: UInt64, deadline: UInt64) -> VoiceAudioDrainDecision {
        guard let isRunning else { return .forceRetire }
        if isRunning == 0 { return .drained }
        return now >= deadline ? .forceRetire : .wait
    }

    static func deadline(after now: UInt64) -> UInt64 {
        let (value, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : value
    }
}

enum VoiceAudioCatalog {
    static let inputUID = "OpenRemoteAudio_UID"
    static let outputUID = "OpenRemoteAudio_2_UID"
    static let pluginBundleID = "org.rc001remote.audio"
    static let manufacturer = "OpenRemote contributors"
    static let inputName = "遥控器麦克风"
    static let outputName = "遥控器麦克风（内部输出）"
    // The public input reports USB transport for compatibility with clients
    // that filter ordinary virtual microphones. The hidden writer endpoint
    // keeps its truthful Virtual transport. Exact UID/provider/channel checks
    // remain mandatory, so transport metadata alone never selects a route.
    static let inputTransport = kAudioDeviceTransportTypeUSB
    static let outputTransport = kAudioDeviceTransportTypeVirtual

    /// Names are checked for a consistent product installation, but identity
    /// never relies on names alone. This is routing validation, not a security
    /// boundary against another privileged process impersonating the driver.
    private static func acceptsBaseIdentity(input: VoiceEndpointIdentity, output: VoiceEndpointIdentity) -> Bool {
        func owned(_ endpoint: VoiceEndpointIdentity) -> Bool {
            endpoint.pluginBundleID == pluginBundleID && endpoint.manufacturer == manufacturer
                && endpoint.isAlive
        }
        return owned(input) && owned(output)
            && input.uid == inputUID && input.name == inputName
            && output.uid == outputUID && output.name == outputName
            && input.inputChannels == 2 && input.outputChannels == 0
            && output.inputChannels == 0 && output.outputChannels == 2
    }

    static func compatibility(input: VoiceEndpointIdentity,
                              output: VoiceEndpointIdentity) -> VoiceAudioCatalogCompatibility {
        guard acceptsBaseIdentity(input: input, output: output), output.transport == outputTransport else {
            return .invalid
        }
        if input.transport == inputTransport { return .current }
        // 0.2.4 and earlier used this otherwise-identical, all-Virtual pair.
        // It is recognized only so an installed 0.2.5 bundle can offer one
        // explicit CoreAudio reload after an upgrade; it is never a valid route.
        if input.transport == kAudioDeviceTransportTypeVirtual { return .previousVirtualInput }
        return .invalid
    }

    static func accepts(input: VoiceEndpointIdentity, output: VoiceEndpointIdentity) -> Bool {
        compatibility(input: input, output: output) == .current
    }

    static func devices() -> [VoiceAudioDevice] {
        guard let endpoints = snapshot(), endpoints.compatibility == .current else { return [] }
        // The UID below is the hidden output endpoint. The visible input name
        // is presented to the user and is what receiving applications select.
        return [VoiceAudioDevice(uid: outputUID, name: inputName, deviceID: endpoints.output)]
    }

    /// The input endpoint exposed to receiving applications. Returning it
    /// requires the same provider, identity, visibility, channel and ownership
    /// checks as the hidden output used by this application.
    static func inputDevice() -> VoiceAudioDevice? {
        guard let endpoints = snapshot(), endpoints.compatibility == .current else { return nil }
        return VoiceAudioDevice(uid: inputUID, name: inputName, deviceID: endpoints.input)
    }

    /// Returns a pair only after all identity, provider, visibility, channel and
    /// liveness checks pass. Compatibility then distinguishes the current USB
    /// public input from the otherwise-identical pre-0.2.5 Virtual input.
    static func snapshot() -> VoiceAudioCatalogSnapshot? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 65_536, size % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0 else { return nil }
        let capacity = Int(size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard let count = VoiceAudioBufferLayout.validatedDeviceCount(status: result, byteCount: Int(size), capacity: capacity) else { return nil }
        ids = Array(ids.prefix(count))
        let inputs = ids.filter { string($0, kAudioDevicePropertyDeviceUID) == inputUID }
        guard inputs.count == 1, let inputID = inputs.first,
              let outputID = translate(outputUID), outputID != inputID,
              scalar(inputID, kAudioDevicePropertyIsHidden) == 0,
              scalar(inputID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                     scope: kAudioDevicePropertyScopeInput) == 1,
              scalar(outputID, kAudioDevicePropertyIsHidden) == 1,
              let provider = provider(), provider.matches(input: inputID, output: outputID),
              let input = identity(inputID, provider: provider), let output = identity(outputID, provider: provider) else { return nil }
        return VoiceAudioCatalogSnapshot(compatibility: compatibility(input: input, output: output),
                                         input: inputID, output: outputID)
    }

    private static func translate(_ uid: String, object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                                  selector: AudioObjectPropertySelector = kAudioHardwarePropertyTranslateUIDToDevice) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = uid as CFString
        var qualifier = Unmanaged.passUnretained(value)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = withExtendedLifetime(value) {
            AudioObjectGetPropertyData(object, &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &size, &device)
        }
        return result == noErr && size == MemoryLayout<AudioObjectID>.size && device != kAudioObjectUnknown ? device : nil
    }

    private static func provider() -> VoiceAudioProvider? {
        guard let pluginID = translate(pluginBundleID, selector: kAudioHardwarePropertyTranslateBundleIDToPlugIn),
              let bundleID = string(pluginID, kAudioPlugInPropertyBundleID),
              let classID = scalar(pluginID, kAudioObjectPropertyClass),
              let input = translate(inputUID, object: pluginID, selector: kAudioPlugInPropertyTranslateUIDToDevice),
              let output = translate(outputUID, object: pluginID, selector: kAudioPlugInPropertyTranslateUIDToDevice) else { return nil }
        return VoiceAudioProvider(pluginID: pluginID, classID: classID, bundleID: bundleID,
            inputDeviceID: input, outputDeviceID: output)
    }

    private static func identity(_ id: AudioDeviceID, provider: VoiceAudioProvider) -> VoiceEndpointIdentity? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName),
              let manufacturer = string(id, kAudioObjectPropertyManufacturer),
              let transport = scalar(id, kAudioDevicePropertyTransportType),
              let alive = scalar(id, kAudioDevicePropertyDeviceIsAlive),
              let inputChannels = channels(id, kAudioDevicePropertyScopeInput),
              let outputChannels = channels(id, kAudioDevicePropertyScopeOutput) else { return nil }
        return VoiceEndpointIdentity(uid: uid, name: name, manufacturer: manufacturer,
            pluginBundleID: provider.bundleID, transport: transport,
            inputChannels: inputChannels, outputChannels: outputChannels, isAlive: alive == 1)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Unmanaged<CFString>?>.size else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
            && size == MemoryLayout<UInt32>.size ? value : nil
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= header, size <= 65_536 else { return nil }
        let capacity = Int(size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        let result = AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
        guard let count = VoiceAudioBufferLayout.validatedBufferCount(status: result, byteCount: Int(size),
            capacity: capacity, announced: raw.load(as: UInt32.self)) else { return nil }
        let buffers = raw.advanced(by: header).assumingMemoryBound(to: AudioBuffer.self)
        return (0..<count).reduce(0) { $0 + Int(buffers[$1].mNumberChannels) }
    }
}

/// Bounded PCM playback into the selected loopback. AudioQueue is bound to an
/// explicit UID before its first buffer; it never tracks the default output.
/// Each hold owns a fresh queue. A normal release drains already-enqueued PCM
/// for at most 750 ms; failure, disconnect and quit still stop immediately.
final class VoiceAudioOutput {
    var onFailure: ((String) -> Void)?
    private(set) var lastEnqueueFailureMessage: String?
    /// AudioQueueDispose(..., true) waits for pending buffer callbacks. Those
    /// callbacks must never run on the main queue, because every public method
    /// below is main-thread confined and stop() can be reached directly from a
    /// CoreBluetooth main-queue callback.
    private let callbackQueue = DispatchQueue(label: "org.rc001remote.assistant.voice-audio-callback",
        qos: .userInitiated)
    /// Immediate disposal is deliberately synchronous inside this worker, but
    /// the UI only detaches a queue and submits that bounded teardown.
    private static let teardownQueue = DispatchQueue(label: "org.rc001remote.assistant.voice-audio-teardown",
        qos: .userInitiated)
    private struct RetiringQueue {
        let id: UInt64
        let queue: AudioQueueRef
        let deadline: UInt64
        let completion: (() -> Void)?
    }
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var selectedUID: String?
    private var generation: UInt64 = 0
    private var started = false
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var routeTimer: Timer?
    private var queueBudget = VoiceAudioQueueBudget(limit: 2)
    private var retirements: [UInt64: RetiringQueue] = [:]
    private var nextRetirementID: UInt64 = 0
    private var drainPoll: DispatchWorkItem?
    // 96 buffers remain below 400 KiB and can atomically accept the controller's
    // bounded five-second pre-roll (80,000 mono samples -> 79 stereo buffers).
    // Steady-state BLE frames are returned by AudioQueue callbacks as before.
    private static let bufferCount = 96
    private static let bufferBytes: UInt32 = 4_096

    deinit { stop() }

    @discardableResult
    func start(deviceUID: String) -> String? {
        precondition(Thread.isMainThread)
        // A prior normal hold may still be draining while Typeless completes
        // its closing Fn tap. Retiring queues are bounded separately and must
        // keep their completion; only replace an unexpectedly active queue.
        if let active = detachActiveQueue()?.queue { dispose(active) }
        guard queueBudget.canCreate else {
            return "上一段遥控器音频仍在释放，请等待片刻后重新连接；未创建更多音频队列。"
        }
        guard VoiceAudioCatalog.devices().filter({ $0.uid == deviceUID }).count == 1 else {
            return "遥控器麦克风组件未就绪，请重新运行完整安装包；不会改用扬声器。"
        }
        generation &+= 1
        let token = generation
        // Duplicate the mono remote into channels 1 and 2. AudioQueue converts
        // the 16 kHz client format to the device rate without changing that rate.
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var created: AudioQueueRef?
        let result = AudioQueueNewOutputWithDispatchQueue(&created, &format, 0, callbackQueue) { [weak self] output, buffer in
            // Keep the buffer pool main-thread confined. A retired queue may
            // finish a callback after stop() has detached it, so both the hold
            // generation and exact queue identity are checked before reuse.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.queue == output else { return }
                self.buffers.append(buffer)
            }
        }
        guard result == noErr, let created else { return "无法建立虚拟音频输出（\(result)）。" }
        guard queueBudget.didCreate() else {
            Self.teardownQueue.async { AudioQueueDispose(created, true) }
            return "音频资源数量异常；未启用遥控器麦克风。"
        }
        queue = created
        selectedUID = deviceUID
        let uidObject = deviceUID as CFString
        var uid = Unmanaged.passUnretained(uidObject)
        let routed = withExtendedLifetime(uidObject) {
            AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, &uid,
                                  UInt32(MemoryLayout<Unmanaged<CFString>>.size))
        }
        guard routed == noErr, routeMatches() else { stop(); return "无法确认遥控器麦克风的专用输出路由；未发送音频。" }
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(created, Self.bufferBytes, &buffer) == noErr, let buffer else {
                stop(); return "无法分配有界音频缓冲区。"
            }
            buffers.append(buffer)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.generation == token else { return }
            self.checkRoute()
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else {
            stop(); return "无法监控音频设备移除；为避免误路由，未启用音频。"
        }
        deviceListListener = listener
        routeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkRoute() }
        return nil
    }

    @discardableResult
    func enqueue(_ samples: [Int16]) -> Bool {
        precondition(Thread.isMainThread)
        lastEnqueueFailureMessage = nil
        guard !samples.isEmpty else { return true }
        guard let queue else {
            lastEnqueueFailureMessage = "虚拟音频输出尚未建立。"
            return false
        }
        guard routeMatches() else {
            lastEnqueueFailureMessage = "虚拟音频专用输出已离线或路由发生变化。"
            return false
        }
        let samplesPerBuffer = Int(Self.bufferBytes) / 4
        guard let ranges = VoiceAudioChunkPlan.ranges(sampleCount: samples.count,
                samplesPerBuffer: samplesPerBuffer, availableBuffers: buffers.count) else {
            let required = VoiceAudioChunkPlan.requiredBufferCount(
                sampleCount: samples.count, samplesPerBuffer: samplesPerBuffer) ?? 0
            lastEnqueueFailureMessage = "虚拟音频队列暂时没有足够空间（需要 \(required) 个缓冲区，当前 \(buffers.count) 个）。"
            return false
        }
        let claimed = Array(buffers.suffix(ranges.count))
        buffers.removeLast(ranges.count)
        for (index, range) in ranges.enumerated() {
            let buffer = claimed[index]
            let destination = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
            for (offset, sourceIndex) in range.enumerated() {
                destination[2 * offset] = samples[sourceIndex]
                destination[2 * offset + 1] = samples[sourceIndex]
            }
            buffer.pointee.mAudioDataByteSize = UInt32(range.count * 4)
            let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            guard status == noErr else {
                if index + 1 < claimed.count {
                    buffers.append(contentsOf: claimed[(index + 1)...])
                }
                lastEnqueueFailureMessage = "CoreAudio 拒绝写入虚拟音频队列（\(status)）。"
                return false
            }
        }
        if !started {
            guard routeMatches() else {
                lastEnqueueFailureMessage = "虚拟音频在启动前已离线或路由发生变化。"
                return false
            }
            let status = AudioQueueStart(queue, nil)
            guard status == noErr else {
                lastEnqueueFailureMessage = "CoreAudio 无法启动虚拟音频队列（\(status)）。"
                return false
            }
            started = true
        }
        return true
    }

    func stop() {
        precondition(Thread.isMainThread)
        drainPoll?.cancel(); drainPoll = nil
        let active = detachActiveQueue()?.queue
        let pending = Array(retirements.values)
        retirements.removeAll()
        // `finishAfterDraining` promises a one-shot convergence callback. An
        // error, disconnect, or app shutdown may force immediate disposal while
        // a normal release is still retiring; complete those waiters before
        // releasing their queues so the Typeless controller cannot remain
        // stranded in `.draining`.
        pending.forEach { $0.completion?() }
        for retired in ([active].compactMap { $0 } + pending.map(\.queue)) { dispose(retired) }
    }

    /// Preserve the final already-enqueued PCM after a normal physical release.
    /// AudioQueueStop(false) processes queued buffers asynchronously. We retain
    /// the queue until IsRunning becomes zero, with a hard deadline so a broken
    /// driver cannot accumulate resources or keep the application alive.
    func finishAfterDraining(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard let detached = detachActiveQueue() else {
            completion?()
            return
        }
        guard detached.wasStarted else {
            dispose(detached.queue)
            completion?()
            return
        }
        let status = AudioQueueStop(detached.queue, false)
        guard status == noErr else {
            NSLog("无法开始音频尾部排空（%d）；立即释放。", status)
            dispose(detached.queue)
            completion?()
            return
        }
        nextRetirementID &+= 1
        let now = DispatchTime.now().uptimeNanoseconds
        let retirement = RetiringQueue(id: nextRetirementID, queue: detached.queue,
            deadline: VoiceAudioDrainPolicy.deadline(after: now), completion: completion)
        retirements[retirement.id] = retirement
        checkRetirements()
    }

    private func routeMatches() -> Bool {
        guard let queue, let selectedUID else { return false }
        var actual: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &actual, &size) == noErr else { return false }
        // AudioQueueGetProperty duplicates CF objects despite its Get name;
        // Apple's API contract gives ownership of this returned UID to us.
        return actual?.takeRetainedValue() as String? == selectedUID
    }

    private func checkRoute() {
        guard let selectedUID else { return }
        guard routeMatches(), VoiceAudioCatalog.devices().filter({ $0.uid == selectedUID }).count == 1 else {
            stop()
            onFailure?("遥控器麦克风组件已移除或路由改变；已停止推流，不回退到扬声器。")
            return
        }
    }

    private func detachActiveQueue() -> (queue: AudioQueueRef, wasStarted: Bool)? {
        generation &+= 1
        routeTimer?.invalidate(); routeTimer = nil
        if let listener = deviceListListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListListener = nil
        guard let detached = queue else {
            buffers.removeAll(); selectedUID = nil; started = false
            return nil
        }
        let wasStarted = started
        queue = nil; buffers.removeAll(); selectedUID = nil; started = false
        return (detached, wasStarted)
    }

    private func queueIsRunning(_ queue: AudioQueueRef) -> UInt32? {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) == noErr
            && size == MemoryLayout<UInt32>.size ? running : nil
    }

    private func checkRetirements() {
        precondition(Thread.isMainThread)
        drainPoll?.cancel(); drainPoll = nil
        let now = DispatchTime.now().uptimeNanoseconds
        var finished: [(RetiringQueue, Bool)] = []
        for retirement in Array(retirements.values) {
            switch VoiceAudioDrainPolicy.decision(isRunning: queueIsRunning(retirement.queue),
                                                  now: now, deadline: retirement.deadline) {
            case .wait: break
            case .drained:
                retirements.removeValue(forKey: retirement.id)
                finished.append((retirement, true))
            case .forceRetire:
                retirements.removeValue(forKey: retirement.id)
                finished.append((retirement, false))
            }
        }
        for (retirement, drained) in finished {
            if drained {
                NSLog("遥控器音频尾部已排空。")
            } else {
                NSLog("遥控器音频尾部排空状态不可用或超过 0.75 秒；已强制释放。")
            }
            retirement.completion?()
            dispose(retirement.queue)
        }
        guard !retirements.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.drainPoll = nil
            self?.checkRetirements()
        }
        drainPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
    }

    private func dispose(_ retiredQueue: AudioQueueRef) {
        // Immediate disposal can wait for callbacks. The queue has already been
        // detached, so teardown stays off the main/UI/Bluetooth queue.
        Self.teardownQueue.async {
            let result = AudioQueueDispose(retiredQueue, true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if result == noErr {
                    self.queueBudget.didDispose()
                } else {
                    self.onFailure?("系统未能释放上一段音频队列（\(result)）；已停止发送，请重新打开遥控器助手。")
                }
            }
        }
    }
}
