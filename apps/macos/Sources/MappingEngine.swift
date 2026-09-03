// SPDX-License-Identifier: GPL-3.0-only
// Portions Copyright (C) 2026 SayAll contributors
// Modifications Copyright (C) 2026 OpenRemoteAssistant contributors
// Modified 2026-09-03.
// Shared-reading and event-suppression portions adapted from
// HD838A/remote-mic-app commit 9e019112fc88534004641499b0b1efc50b491e5e.

import AppKit
import ApplicationServices
import IOKit.hid

// The event tap
// suppresses only native events that immediately correspond to a report from
// the already-bound RC003-MS; synthetic mapping output carries a marker and is
// always allowed through.
enum RemoteNativeEvent: Hashable {
    case keyboard(UInt16)
    case systemKey(Int32)
}

enum RemoteNativeEventEdge { case down, up }

private func remoteKeyboardSuppressorCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<RemoteKeyboardEventSuppressor>
        .fromOpaque(userInfo).takeUnretainedValue()
    return suppressor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

private final class RemoteKeyboardEventSuppressor {
    private static let systemDefinedEventType: UInt32 = 14
    private struct Pending {
        let event: RemoteNativeEvent
        let edge: RemoteNativeEventEdge
        let expires: TimeInterval
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var held: [RemoteNativeEvent: Int] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false

    func start() -> Bool {
        if isRunning { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << Self.systemDefinedEventType)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: remoteKeyboardSuppressorCallback, userInfo: context),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        lock.lock(); pending.removeAll(); held.removeAll(); lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil; tap = nil; isRunning = false
    }

    func arm(button: RemoteButton, edge: RemoteNativeEventEdge) {
        let events = button.nativeEvents
        guard !events.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pending.removeAll { $0.expires <= now }
        for event in events {
            switch edge {
            case .down:
                held[event, default: 0] += 1
            case .up:
                if let index = pending.firstIndex(where: { $0.event == event && $0.edge == .down }) {
                    pending.remove(at: index)
                }
                let remaining = (held[event] ?? 0) - 1
                if remaining > 0 { held[event] = remaining } else { held.removeValue(forKey: event) }
            }
            pending.append(Pending(event: event, edge: edge, expires: now + 0.18))
        }
        if pending.count > 32 { pending.removeFirst(pending.count - 32) }
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == MappingEngine.injectedEventMarker {
            return false
        }
        guard let descriptor = descriptor(type: type, event: event) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pending.removeAll { $0.expires <= now }
        if let index = pending.firstIndex(where: {
            $0.event == descriptor.0 && $0.edge == descriptor.1
        }) {
            pending.remove(at: index); lock.unlock(); return true
        }
        if descriptor.1 == .down, (held[descriptor.0] ?? 0) > 0 {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                held.removeValue(forKey: descriptor.0); lock.unlock(); return false
            }
            lock.unlock(); return true
        }
        lock.unlock(); return false
    }

    private func descriptor(type: CGEventType, event: CGEvent)
        -> (RemoteNativeEvent, RemoteNativeEventEdge)? {
        if type.rawValue == Self.systemDefinedEventType {
            guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
            let key = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
            let state = (nsEvent.data1 & 0x0000_FF00) >> 8
            guard state == 0xA || state == 0xB else { return nil }
            return (.systemKey(key), state == 0xA ? .down : .up)
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        return (.keyboard(UInt16(event.getIntegerValueField(.keyboardEventKeycode))),
                type == .keyDown ? .down : .up)
    }
}

extension RemoteButton {
    var nativeEvents: Set<RemoteNativeEvent> {
        switch self {
        case .ok: return [.keyboard(36)]
        case .tv: return [.keyboard(10), .keyboard(50)]
        case .home: return [.keyboard(115)]
        case .right: return [.keyboard(124)]
        case .left: return [.keyboard(123)]
        case .down: return [.keyboard(125)]
        case .up: return [.keyboard(126)]
        case .menu: return [.keyboard(110)]
        case .power: return [.keyboard(90)]
        case .microphone: return [.keyboard(96)]
        case .volumeUp: return [.systemKey(0)]
        case .volumeDown: return [.systemKey(1)]
        case .back: return []
        }
    }
}

/// RC003 keyboard report 1 contains three little-endian UInt16 usages. macOS
/// may provide either the six-byte payload or a seven-byte buffer prefixed by
/// the report ID. Vendor reports can contain microphone data and are ignored.
enum RC003HIDReport {
    case keys(Set<UInt16>), ignored, malformed

    static func parse(id: UInt32, bytes: [UInt8]) -> RC003HIDReport {
        guard id == 1 else { return .ignored }
        let payload: ArraySlice<UInt8>
        if bytes.count == 6 { payload = bytes[...] }
        else if bytes.count == 7, bytes[0] == 1 { payload = bytes.dropFirst() }
        else { return .malformed }
        var usages = Set<UInt16>()
        let values = Array(payload)
        for offset in stride(from: 0, through: 4, by: 2) {
            let usage = UInt16(values[offset]) | UInt16(values[offset + 1]) << 8
            // The HID keyboard error usages do not describe a reliable release.
            guard !(1...3).contains(usage) else { return .malformed }
            if usage != 0 { usages.insert(usage) }
        }
        return .keys(usages)
    }
}

enum MappingOutputEvent: Equatable {
    case keyboard(code: UInt16, down: Bool, flags: UInt64, modifier: Bool)
    case systemKey(code: UInt16, down: Bool)
}

/// A pure state machine: tests exercise releases without opening a device or
/// injecting a key. Each pressed remote key retains its original binding until
/// released. Shared output keys/modifiers stay down until their last owner ends.
struct MappingInputState {
    private(set) var physicalUsages = Set<UInt16>()
    private(set) var heldActions: [UInt16: MappingAction] = [:]
    static let verifiedUsages = Set(RemoteButton.allCases.filter(\.isVerifiedHIDInput).map(\.usage))
    static let modifierKeys: [(flag: UInt64, code: UInt16)] = [
        (CGEventFlags.maskControl.rawValue, 59),
        (CGEventFlags.maskAlternate.rawValue, 58),
        (CGEventFlags.maskShift.rawValue, 56),
        (CGEventFlags.maskCommand.rawValue, 55),
        // Apple SDK: Events.h kVK_Function = 0x3F; CGEventTypes.h maps
        // maskSecondaryFn to NX_SECONDARYFNMASK (0x00800000). This represents
        // a CGEvent Fn modifier; it is not equivalent to a hardware Globe key
        // and does not promise to invoke macOS Dictation or other system UI.
        (CGEventFlags.maskSecondaryFn.rawValue, 63)
    ]

    struct Output {
        var keys = Set<UInt16>()
        var systemKeys = Set<UInt16>()
        var flags: UInt64 = 0
        init(_ actions: [UInt16: MappingAction]) {
            for action in actions.values {
                switch action {
                case .shortcut(let combo):
                    keys.insert(combo.keyCode)
                    flags |= combo.modifiers
                case .modifier(let flag): flags |= flag
                case .systemKey(let code): systemKeys.insert(code)
                case .disabled: break
                }
            }
        }
    }

    mutating func consume(_ hidUsages: Set<UInt16>, mappings: [UInt16: MappingAction],
                          voiceButtonPressed: Bool = false) -> [MappingOutputEvent] {
        // HID 0x3E remains unverified. It cannot activate the microphone mapping,
        // even when this code appears alongside real GATT edges. Only the
        // explicit GATT boolean contributes that virtual button to the union.
        var usages = hidUsages.intersection(Self.verifiedUsages)
        if voiceButtonPressed { usages.insert(RemoteButton.microphone.usage) }
        let before = Output(heldActions)
        for usage in physicalUsages.subtracting(usages) { heldActions.removeValue(forKey: usage) }
        for usage in usages.subtracting(physicalUsages) {
            if let action = mappings[usage], action.isValid { heldActions[usage] = action }
        }
        physicalUsages = usages
        return Self.transition(from: before, to: Output(heldActions))
    }

    /// A changed binding must not fire while the physical key is already held.
    mutating func releaseOutputs(keepPhysicalUsages: Bool) -> [MappingOutputEvent] {
        let before = Output(heldActions)
        heldActions.removeAll()
        if !keepPhysicalUsages { physicalUsages.removeAll() }
        return Self.transition(from: before, to: Output([:]))
    }

    private static func transition(from old: Output, to new: Output) -> [MappingOutputEvent] {
        var result: [MappingOutputEvent] = []
        // Release main keys before their modifiers, including on disable/exit.
        for code in old.keys.subtracting(new.keys).sorted() {
            result.append(.keyboard(code: code, down: false, flags: old.flags, modifier: false))
        }
        for code in old.systemKeys.subtracting(new.systemKeys).sorted() {
            result.append(.systemKey(code: code, down: false))
        }
        var flags = old.flags
        for key in modifierKeys.reversed() where old.flags & key.flag != 0 && new.flags & key.flag == 0 {
            flags &= ~key.flag
            result.append(.keyboard(code: key.code, down: false, flags: flags, modifier: true))
        }
        for key in modifierKeys where old.flags & key.flag == 0 && new.flags & key.flag != 0 {
            flags |= key.flag
            result.append(.keyboard(code: key.code, down: true, flags: flags, modifier: true))
        }
        for code in new.keys.subtracting(old.keys).sorted() {
            result.append(.keyboard(code: code, down: true, flags: new.flags, modifier: false))
        }
        for code in new.systemKeys.subtracting(old.systemKeys).sorted() {
            result.append(.systemKey(code: code, down: true))
        }
        return result
    }
}

/// No event tap, global keyboard reader, hidutil map, login agent, or automatic
/// reconnect. Creating this object does not open any HID device.
final class MappingEngine {
    static let injectedEventMarker: Int64 = 0x5243_3030_314D_4150
    var onStatus: ((EngineStatus) -> Void)?
    var onInput: ((Set<UInt16>) -> Void)?
    /// Ordinary-app coordinator closes its authenticated socket. This engine
    /// never requests administrator authorization or starts a helper itself.
    var onRequestBridgeStop: (() -> Void)?
    private(set) var status = EngineStatus(isEnabled: false, message: "映射未启用；按键由 macOS 处理", deviceConnected: false)

    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var reportCapacity = 0
    private var callbackContext: CallbackContext?
    private var generation: UInt64 = 0
    private var mappings: [UInt16: MappingAction] = [:]
    private var input = MappingInputState()
    private var hidUsages = Set<UInt16>()
    private var voiceButtonPressed = false
    private var eventSource: CGEventSource?
    private var targetBinding: DeviceBinding?
    private var usingBridge = false
    private var deviceWasSeized = false
    private let eventSuppressor = RemoteKeyboardEventSuppressor()

    private final class CallbackContext {
        weak var engine: MappingEngine?
        let generation: UInt64
        init(engine: MappingEngine, generation: UInt64) {
            self.engine = engine
            self.generation = generation
        }
    }

    deinit { tearDown() }

    /// Configuring identity never opens hardware. A target change releases the
    /// old device before accepting another user-confirmed local binding.
    func configureTarget(_ binding: DeviceBinding?) {
        precondition(Thread.isMainThread)
        guard binding != targetBinding else { return }
        disable()
        targetBinding = binding?.isValid == true ? binding : nil
        refreshConnectionStatus()
    }

    func enable(mappings requested: [UInt16: MappingAction]) {
        precondition(Thread.isMainThread)
        if status.isEnabled { updateMappings(requested); return }
        guard permissionsGranted else {
            publish(enabled: false, message: permissionMessage, connected: targetDevice() != nil)
            return
        }
        guard let validated = Self.validatedMappings(requested) else {
            publish(enabled: false, message: "配置含不支持的按键；未接管遥控器", connected: status.deviceConnected)
            return
        }
        guard let binding = targetBinding, binding.isValid, binding.hid != nil else {
            publish(enabled: false, message: "请先确认这只遥控器的本机 HID 绑定；纯音频不需要 HID 绑定。", connected: false)
            return
        }
        guard let target = targetDevice() else {
            publish(enabled: false, message: "本机 HID 绑定缺失、已改变或候选不唯一；请重新确认，未接管任何设备。", connected: false)
            return
        }
        let maximum = (IOHIDDeviceGetProperty(target, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 512
        guard maximum >= 6, maximum <= 4096 else {
            publish(enabled: false, message: "设备报告格式不在支持范围；未接管遥控器", connected: true)
            return
        }
        // Prefer true device seizure. macOS commonly reserves Bluetooth remote
        // keyboards and refuses that operation, so fall back to ordinary shared
        // report reading plus a narrowly armed event tap, matching the proven
        // upstream strategy. This path needs only this app's two visible TCC
        // permissions and never starts an administrator helper.
        let seize = IOHIDDeviceOpen(target, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if seize == kIOReturnSuccess {
            deviceWasSeized = true
        } else {
            _ = IOHIDDeviceClose(target, IOOptionBits(kIOHIDOptionsTypeNone))
            let monitored = IOHIDDeviceOpen(target, IOOptionBits(kIOHIDOptionsTypeNone))
            guard monitored == kIOReturnSuccess else {
                publish(enabled: false,
                    message: "无法读取已绑定遥控器（独占 \(seize)，共享 \(monitored)）；请关闭其他按键工具后重试。",
                    connected: true)
                return
            }
            guard eventSuppressor.start() else {
                _ = IOHIDDeviceClose(target, IOOptionBits(kIOHIDOptionsTypeNone))
                publish(enabled: false,
                    message: "无法建立原按键屏蔽；请重新确认辅助功能权限后重试。",
                    connected: true)
                return
            }
            deviceWasSeized = false
        }
        device = target
        mappings = validated
        input = MappingInputState()
        hidUsages.removeAll()
        voiceButtonPressed = false
        generation &+= 1
        let context = CallbackContext(engine: self, generation: generation)
        callbackContext = context
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        reportCapacity = max(64, maximum)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportCapacity)
        buffer.initialize(repeating: 0, count: reportCapacity)
        reportBuffer = buffer
        IOHIDDeviceRegisterInputReportCallback(target, buffer, reportCapacity, { context, result, _, type, reportID, bytes, count in
            guard let context else { return }
            let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            guard let engine = callback.engine, engine.generation == callback.generation, engine.status.isEnabled else { return }
            guard result == kIOReturnSuccess else { engine.failClosed("设备读取失败；已停止映射并释放遥控器"); return }
            guard type == kIOHIDReportTypeInput, reportID == 1 else { return }
            guard count == 6 || count == 7 else { engine.failClosed("收到异常按键报告；已停止映射并释放遥控器"); return }
            engine.receive(RC003HIDReport.parse(id: reportID, bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
        }, opaque)
        IOHIDDeviceRegisterRemovalCallback(target, { context, _, _ in
            guard let context else { return }
            let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            guard let engine = callback.engine, engine.generation == callback.generation else { return }
            engine.failClosed("遥控器已断开；映射已停止，重连后请手动启用", connected: false)
        }, opaque)
        status.isEnabled = true
        IOHIDDeviceScheduleWithRunLoop(target, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        publish(enabled: true,
            message: deviceWasSeized
                ? "映射已启用 · 已独占这只 RC003-MS"
                : "映射已启用 · 正在共享读取并屏蔽这只 RC003-MS 的原按键",
            connected: true)
    }

    /// Called only after the ordinary app authenticated a matching ready frame
    /// from its root HID session. All key construction/posting stays here.
    @discardableResult
    func enableFromBridge(mappings requested: [UInt16: MappingAction], target: HIDDeviceCandidate) -> Bool {
        precondition(Thread.isMainThread)
        guard !status.isEnabled else { return false }
        guard permissionsGranted else {
            publish(enabled: false, message: permissionMessage, connected: status.deviceConnected)
            return false
        }
        guard let binding = targetBinding, binding.isValid, let bound = binding.hid,
              target.isValid, target.registryID == bound.registryID, target.locationID == bound.locationID,
              targetDevice() != nil, let validated = Self.validatedMappings(requested) else {
            publish(enabled: false, message: "按键会话与本机绑定或映射配置不一致；未启用映射。", connected: false)
            return false
        }
        mappings = validated
        input = MappingInputState(); hidUsages.removeAll(); voiceButtonPressed = false
        generation &+= 1; usingBridge = true
        publish(enabled: true, message: "映射已启用 · 独立会话仅接管这只 RC003-MS", connected: true)
        return true
    }

    func receiveBridgeUsages(_ usages: Set<UInt16>) {
        precondition(Thread.isMainThread)
        guard status.isEnabled, usingBridge else { return }
        guard permissionsGranted else { failClosed("系统权限已撤销；已停止映射并请求释放按键"); return }
        guard usages.count <= 3, usages.isSubset(of: MappingInputState.verifiedUsages) else {
            failClosed("按键辅助进程返回了无效状态；已停止映射并释放会话。")
            return
        }
        applyInput(hid: usages, voice: voiceButtonPressed)
    }

    func bridgeDidStop(_ message: String) {
        precondition(Thread.isMainThread)
        guard usingBridge else { return }
        usingBridge = false
        failClosed(message)
    }

    func updateMappings(_ requested: [UInt16: MappingAction]) {
        precondition(Thread.isMainThread)
        guard let validated = Self.validatedMappings(requested) else {
            failClosed("配置含不支持的按键；已停止映射")
            return
        }
        var next = input
        let releases = next.releaseOutputs(keepPhysicalUsages: true)
        guard post(releases) else { failClosed("无法释放已按下的映射键；已停止映射"); return }
        input = next
        mappings = validated
    }

    /// Accepts an independently identified GATT voice-button edge. It never opens
    /// Bluetooth/audio itself, and an inactive mapper cannot inject via this API.
    func setVoiceButtonPressed(_ down: Bool) {
        precondition(Thread.isMainThread)
        guard status.isEnabled else { return }
        guard permissionsGranted else { failClosed("系统权限已撤销；已停止映射并请求释放按键"); return }
        guard down != voiceButtonPressed else { return }
        applyInput(hid: hidUsages, voice: down)
    }

    func disable() {
        precondition(Thread.isMainThread)
        let connected = status.deviceConnected
        tearDown()
        onInput?([])
        publish(enabled: false, message: "映射未启用；按键由 macOS 处理", connected: connected)
    }

    /// Read-only metadata enumeration while disabled; while active this checks
    /// permission revocation. The app calls it every two seconds on the main loop.
    func refreshConnectionStatus() {
        precondition(Thread.isMainThread)
        if status.isEnabled {
            if !permissionsGranted { failClosed("系统权限已撤销；已停止映射并请求释放按键") }
            else if targetDevice() == nil { failClosed("设备绑定已改变或出现另一只候选遥控器；已停止映射。", connected: false) }
            return
        }
        let connected = targetDevice() != nil
        if connected != status.deviceConnected {
            publish(enabled: false, message: status.message, connected: connected)
        }
    }

    private var permissionsGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted && AXIsProcessTrusted()
    }
    private var permissionMessage: String {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            return "需要输入监控权限；请在系统设置中允许本程序，然后重新打开"
        }
        return "需要辅助功能权限；请在系统设置中允许本程序后再启用"
    }

    private func receive(_ report: RC003HIDReport) {
        precondition(Thread.isMainThread)
        guard status.isEnabled else { return }
        guard permissionsGranted else { failClosed("系统权限已撤销；已停止映射并请求释放按键"); return }
        switch report {
        case .ignored: return
        case .malformed: failClosed("收到异常按键报告；已停止映射并释放遥控器")
        case .keys(let usages):
            applyInput(hid: usages, voice: voiceButtonPressed)
        }
    }

    private func applyInput(hid: Set<UInt16>, voice: Bool) {
        let verifiedHID = hid.intersection(MappingInputState.verifiedUsages)
        var physical = verifiedHID
        if voice { physical.insert(RemoteButton.microphone.usage) }
        if device != nil, !deviceWasSeized {
            for usage in physical.subtracting(input.physicalUsages) {
                if let button = RemoteButton.allCases.first(where: { $0.usage == usage }) {
                    eventSuppressor.arm(button: button, edge: .down)
                }
            }
            for usage in input.physicalUsages.subtracting(physical) {
                if let button = RemoteButton.allCases.first(where: { $0.usage == usage }) {
                    eventSuppressor.arm(button: button, edge: .up)
                }
            }
        }
        var next = input
        let events = next.consume(verifiedHID, mappings: mappings, voiceButtonPressed: voice)
        // Commit both input sources only after every output event is constructed.
        guard post(events) else { failClosed("无法生成目标按键事件；已停止映射"); return }
        input = next
        hidUsages = verifiedHID
        voiceButtonPressed = voice
        onInput?(input.physicalUsages)
    }

    private func failClosed(_ message: String, connected: Bool? = nil) {
        let connection = connected ?? status.deviceConnected
        tearDown()
        onInput?([])
        publish(enabled: false, message: message, connected: connection)
    }

    private func tearDown() {
        let stopBridge = usingBridge
        usingBridge = false
        status.isEnabled = false
        generation &+= 1
        callbackContext?.engine = nil
        // Best effort even after permission revocation; macOS may then reject
        // injection. HID ownership is released regardless of that outcome.
        _ = post(input.releaseOutputs(keepPhysicalUsages: false))
        hidUsages.removeAll()
        voiceButtonPressed = false
        if let device {
            if let buffer = reportBuffer {
                IOHIDDeviceRegisterInputReportCallback(device, buffer, reportCapacity, nil, nil)
            }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        eventSuppressor.stop()
        device = nil
        deviceWasSeized = false
        callbackContext = nil
        if let buffer = reportBuffer {
            buffer.deinitialize(count: reportCapacity)
            buffer.deallocate()
        }
        reportBuffer = nil
        reportCapacity = 0
        if stopBridge { onRequestBridgeStop?() }
    }

    private func publish(enabled: Bool, message: String, connected: Bool) {
        status = EngineStatus(isEnabled: enabled, message: message, deviceConnected: connected)
        onStatus?(status)
    }

    private static func validatedMappings(_ requested: [UInt16: MappingAction]) -> [UInt16: MappingAction]? {
        var result: [UInt16: MappingAction] = [:]
        for button in RemoteButton.allCases where button.canMap {
            let action = requested[button.usage] ?? MappingDefaults.bindings[button.id] ?? .disabled
            guard action.isValid else { return nil }
            if case .shortcut(let combo) = action {
                guard combo.keyCode < 127, !(54...63).contains(combo.keyCode) else { return nil }
            }
            result[button.usage] = action
        }
        return result
    }

    static func availableDevices() -> [HIDDeviceCandidate] {
        matchingDevices().compactMap(candidate).sorted { $0.registryID < $1.registryID }
    }

    private func targetDevice() -> IOHIDDevice? {
        guard let binding = targetBinding, binding.isValid, let hid = binding.hid else { return nil }
        let devices = Self.matchingDevices()
        let candidates = devices.compactMap(Self.candidate)
        guard devices.count == candidates.count,
              let selected = try? RemoteDiscoveryPolicy.selectHID(candidates, bound: hid) else { return nil }
        return devices.first { Self.candidate($0)?.registryID == selected.registryID }
    }

    private static func candidate(_ device: IOHIDDevice) -> HIDDeviceCandidate? {
        guard let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue else { return nil }
        let service = IOHIDDeviceGetService(device)
        var registry: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &registry) == kIOReturnSuccess else { return nil }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "小米蓝牙语音遥控器"
        let value = HIDDeviceCandidate(locationID: location, registryID: registry, productName: name)
        return value.isValid ? value : nil
    }

    private static func matchingDevices() -> [IOHIDDevice] {
        // Independent devices prevent manager lifecycle calls from propagating
        // to a device. This manager is NEVER opened or scheduled.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        let identity: [String: Int] = [
            kIOHIDVendorIDKey: MappingDefaults.deviceVendor,
            kIOHIDProductIDKey: MappingDefaults.deviceProduct
        ]
        IOHIDManagerSetDeviceMatching(manager, identity as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.filter { device in
            identity.allSatisfy { key, value in
                (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue == value
            } && (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) == "Bluetooth Low Energy"
                && (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue == 1
                && (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue == 6
        }
    }

    private func post(_ steps: [MappingOutputEvent]) -> Bool {
        if steps.isEmpty { return true }
        if eventSource == nil { eventSource = CGEventSource(stateID: .privateState) }
        guard let eventSource else { return false }
        var events: [CGEvent] = []
        for step in steps {
            let event: CGEvent?
            switch step {
            case .keyboard(let code, let down, let flags, let modifier):
                if modifier, code == MacFunctionKeyInjector.functionKeyCode {
                    // Use the same hidSystemState key-down/up construction as
                    // the voice presets. A flagsChanged event from a private
                    // source was not equivalent for every global-hotkey app.
                    event = MacFunctionKeyInjector.makeEvent(
                        down,
                        flags: CGEventFlags(rawValue: flags),
                        marker: Self.injectedEventMarker
                    )
                } else {
                    event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
                    if modifier { event?.type = .flagsChanged }
                    event?.flags = CGEventFlags(rawValue: flags)
                    event?.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                }
            case .systemKey(let code, let down):
                let state = down ? 0xA : 0xB
                event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    subtype: 8, data1: Int(code) << 16 | state << 8, data2: -1)?.cgEvent
            }
            guard let event else { return false }
            event.setIntegerValueField(.eventSourceUserData, value: Self.injectedEventMarker)
            events.append(event)
        }
        // No events have been sent until the full transition is constructed.
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }
}
