import Foundation
import AppKit
import Combine
import IOKit.hid
import ApplicationServices
import UniformTypeIdentifiers

struct SetupDeviceChoice: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isSupported: Bool
}

enum HIDServiceInputPermissionState: String, Equatable {
    case checking
    case granted
    case denied
    case unknown

    var isGranted: Bool { self == .granted }

    static func from(_ status: HIDInputAccessStatus) -> Self {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }

    static func fromSessionFailure(code: String) -> Self? {
        code == "hid_input_access" ? .denied : nil
    }

    static func preview(arguments: [String], plistValue: String?) -> Self {
        for flag in ["--hid-input-preview-state", "--hid-input-access-preview"] {
            if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
               let value = Self(rawValue: arguments[index + 1].lowercased()) {
                return value
            }
        }
        if let plistValue, let value = Self(rawValue: plistValue.lowercased()) { return value }
        return .unknown
    }
}

enum MappingPermissionBlocker: Equatable {
    case mainInputMonitoring
    case accessibility
    case hidServiceRootDenied
    case hidService(HIDServiceInputPermissionState)
}

enum MappingPermissionGate {
    static func blocker(mainInputMonitoring: Bool, accessibility: Bool,
                        hidService: HIDServiceInputPermissionState,
                        rootSessionDenied: Bool = false) -> MappingPermissionBlocker? {
        if !mainInputMonitoring { return .mainInputMonitoring }
        if !accessibility { return .accessibility }
        if rootSessionDenied { return .hidServiceRootDenied }
        if !hidService.isGranted { return .hidService(hidService) }
        return nil
    }
}

enum HIDServicePermissionRefreshPolicy {
    static func permitsCheck(rootSessionDenied: Bool, userInitiated: Bool) -> Bool {
        !rootSessionDenied || userInitiated
    }
}

enum TypelessQuitGate {
    static func canFinish(
        voiceStopped: Bool,
        hidStopped: Bool,
        defaultInputSettled: Bool,
        physicalKeyRestored: Bool
    ) -> Bool {
        voiceStopped && hidStopped && defaultInputSettled && physicalKeyRestored
    }
}

enum AudioInspectionRequestDisposition: Equatable {
    case launch(UInt64)
    case join(UInt64)
    case completeFromTimedOutReading(UInt64)
}

enum AudioInspectionFinishDisposition: Equatable {
    case onTime
    case afterTimeout
}

/// Main-queue state for one potentially blocking CoreAudio catalog read.
/// A UI timeout releases its waiters but deliberately keeps the underlying
/// read in flight, so periodic refreshes cannot accumulate behind a stuck call.
struct AudioInspectionFlightState {
    private(set) var generation: UInt64 = 0
    private(set) var inFlightGeneration: UInt64?
    private(set) var timedOut = false

    mutating func request() -> AudioInspectionRequestDisposition {
        if let inFlightGeneration {
            return timedOut ? .completeFromTimedOutReading(inFlightGeneration) : .join(inFlightGeneration)
        }
        generation &+= 1
        inFlightGeneration = generation
        timedOut = false
        return .launch(generation)
    }

    mutating func markTimedOut(generation: UInt64) -> Bool {
        guard inFlightGeneration == generation, !timedOut else { return false }
        timedOut = true
        return true
    }

    mutating func finish(generation: UInt64) -> AudioInspectionFinishDisposition? {
        guard inFlightGeneration == generation else { return nil }
        let disposition: AudioInspectionFinishDisposition = timedOut ? .afterTimeout : .onTime
        inFlightGeneration = nil
        timedOut = false
        return disposition
    }
}

final class MapperModel: ObservableObject {
    @Published var deviceChoices: [SetupDeviceChoice] = []
    @Published var selectedDeviceChoiceID = "" { didSet { confirmSingleRemote = false } }
    @Published var isSearchingDevices = false
    @Published var isDeviceBound = false
    @Published var confirmSingleRemote = false
    @Published var deviceSetupStatus = "先在系统蓝牙中配对，再查找并确认这一只遥控器。"
    @Published var audioDriverReady = false
    @Published var audioDriverStatus = "正在检查遥控器麦克风组件。"
    @Published var audioDriverNeedsReload = false
    @Published var isReloadingAudioService = false
    @Published var audioServiceReloadStatus = ""
    @Published var audioServiceActionsBlocked = false
    @Published var audioServiceReloadBlocked = false
    @Published var canCheckAudioServiceRecovery = false
    @Published var isCheckingAudioServiceRecovery = false
    @Published var selectedButton: RemoteButton = .ok
    @Published var bindings = MappingDefaults.bindings
    @Published var isMappingEnabled = false
    @Published var isMappingStarting = false
    @Published var isMappingStopping = false
    @Published var mappingSessionStatus = ""
    @Published var isRecording = false
    @Published var lastPressedButtonID: String?
    @Published var connectionText = "正在检查遥控器"
    @Published var inputMonitoringGranted = false
    @Published var accessibilityGranted = false
    @Published var hidServiceInputPermission: HIDServiceInputPermissionState = .unknown
    @Published var hidServiceInputPermissionText = "尚未检查遥控器按键服务的输入监控权限。"
    @Published private(set) var hidServiceSessionVerified = false
    @Published private(set) var hidServiceRootAccessDenied = false
    @Published var saveStatus = "默认配置 · 修改后自动保存"
    @Published var statusText = "映射未启用，遥控器保持系统原有行为。"
    @Published var recordingHint = ""
    @Published var showActivationAlert = false
    @Published var activationError = ""
    @Published var activationOffersInputMonitoringSettings = false
    @Published var isSetupExpanded = false
    @Published var voiceStatusText = "遥控器麦克风未连接。连接后按住右上角语音键说话。"
    @Published var isVoiceEnabled = false
    @Published var audioRoutingEnabled = false
    @Published private(set) var isAudioRoutingStarting = false
    @Published var voiceLevel = 0.0
    @Published var voiceConnectionReady = false
    @Published var voiceIsStreaming = false
    @Published var voiceHasReceivedAudio = false
    @Published var voiceAudioFrames = 0
    @Published var voiceOutputDevices: [VoiceAudioDevice] = []
    @Published var selectedVoiceOutputUID = ""
    @Published private(set) var voiceInputPreset: VoiceInputPreset = .off
    @Published private(set) var voiceShortcutActive = false
    @Published private(set) var typelessInstalled = false
    @Published private(set) var voiceShortcutStatus = "未联动语音软件快捷键。"
    @Published private(set) var isChangingVoiceShortcut = false
    @Published var systemDefaultInputName = "正在检查"
    @Published var remoteMicrophoneIsSystemDefault = false
    @Published var remoteMicrophoneCanBecomeSystemDefault = false
    @Published var canRestorePreviousSystemInput = false
    @Published var previousSystemInputName = ""
    @Published var isChangingSystemDefaultInput = false
    @Published var systemDefaultInputStatus = "有些软件只使用系统默认输入。"
    let isPreview: Bool
    let store: ConfigurationStore
    private let bindingStore: DeviceBindingStore
    private var deviceBinding: DeviceBinding?
    private var discoveredDevices: [RemoteDeviceCandidate] = []
    private var bindingStorageHealthy = true
    private let engine = MappingEngine()
    private let hidSession = HIDSessionClient()
    private let voice = RemoteVoiceService()
    private let voiceFunctionMapper = RemoteVoiceFunctionMapper()
    private let systemDefaultInput = SystemDefaultInputController()
    private var voiceRequested = false
    private var audioRoutingRequested = false
    private var audioRoutingStartGeneration: UInt64 = 0
    private var voiceConnectionParameters: String?
    private var recordingFnHeld = false
    private var localMonitor: Any?
    private var timer: Timer?
    private var recordingTimeout: DispatchWorkItem?
    private var highlightTimeout: DispatchWorkItem?
    private var appInactiveObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var storageHealthy = true
    private var recordedButton: RemoteButton?
    private var audioServiceReload: AudioServiceReloadCoordinator?
    private var previewAudioReload: PreviewAudioServiceReloadExecutor?
    private let audioInspectionQueue = DispatchQueue(label: "org.rc001remote.assistant.audio-inspection", qos: .utility)
    private var audioInspectionFlight = AudioInspectionFlightState()
    private var audioInspectionCompletions: [() -> Void] = []
    private var isLaunchingUninstaller = false
    private var isPreparingToQuit = false
    private var hidInputAccessGeneration: UInt64 = 0
    private var hidInputAccessLastChecked = 0.0
    private var voiceShortcutRecoveryAttempt = 0
    private var voiceShortcutRecoveryWork: DispatchWorkItem?
    private static let voiceInputPresetPreferenceKey = "VoiceInputPreset"
    private static let legacyTypelessPreferenceKey = "TypelessCompatibilityEnabled"
    private static let voiceShortcutRecoveryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    var voiceShortcutEnabled: Bool { voiceInputPreset != .off }

    var audioConnectionBlockedReason: String? {
        if audioServiceActionsBlocked { return "请先在上方确认音频后台操作已结束。" }
        if isPreparingToQuit || isLaunchingUninstaller { return "程序正在退出，不能建立新连接。" }
        if isChangingVoiceShortcut { return "正在切换语音软件快捷键，请稍候。" }
        if !isDeviceBound { return "请先在设备设置中选择并绑定遥控器。" }
        if !audioDriverReady { return "专用音频组件校验尚未通过，请查看下方原因并重新检查。" }
        if voiceShortcutEnabled && !voiceShortcutActive {
            return "语音软件快捷键尚未完成语音键中和；请查看状态后重试。"
        }
        return nil
    }

    var canChangeVoiceInputPreset: Bool {
        !isPreview && !audioServiceActionsBlocked && !isPreparingToQuit && !isLaunchingUninstaller
            && !isChangingVoiceShortcut && !voiceIsStreaming
    }

    var voiceShortcutRestorationPending: Bool {
        !voiceShortcutActive && voiceFunctionMapper.hasPendingRestoration
    }

    var canRequestHIDServiceInputAccess: Bool {
        !isPreview && !audioServiceActionsBlocked && !isPreparingToQuit && !isLaunchingUninstaller
            && !hidSession.isRunning && !hidSession.isCheckingInputAccess && !isRecording
            && hidServiceInputPermission != .granted
    }

    var mappingPermissionsReady: Bool {
        inputMonitoringGranted && accessibilityGranted
    }

    var systemDefaultInputActionTitle: String {
        if remoteMicrophoneIsSystemDefault {
            return canRestorePreviousSystemInput ? "恢复原输入" : "已是默认输入"
        }
        return "设为系统默认输入"
    }

    var canChangeSystemDefaultInput: Bool {
        guard !isPreview, !audioServiceActionsBlocked, !isPreparingToQuit,
              !isLaunchingUninstaller, !isChangingSystemDefaultInput else { return false }
        if remoteMicrophoneIsSystemDefault { return canRestorePreviousSystemInput }
        return audioDriverReady && remoteMicrophoneCanBecomeSystemDefault
    }

    private var hidHelperDigest: String? {
        HIDInstalledHelperContract.helperHash(fromApplicationInfo: Bundle.main.infoDictionary ?? [:])
    }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isPreview = arguments.contains("--ui-preview") || Bundle.main.object(forInfoDictionaryKey: "UIOnlyPreview") as? Bool == true
        typelessInstalled = !isPreview && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "now.typeless.desktop") != nil
        if !isPreview {
            let defaults = UserDefaults.standard
            let initialVoicePreset: VoiceInputPreset
            if let stored = defaults.string(forKey: Self.voiceInputPresetPreferenceKey),
               let preset = VoiceInputPreset(rawValue: stored) {
                initialVoicePreset = preset
            } else if defaults.bool(forKey: Self.legacyTypelessPreferenceKey) {
                initialVoicePreset = .typeless
                defaults.set(VoiceInputPreset.typeless.rawValue, forKey: Self.voiceInputPresetPreferenceKey)
            } else {
                initialVoicePreset = .off
            }
            voiceInputPreset = initialVoicePreset
            voiceShortcutStatus = initialVoicePreset != .off
                ? "正在恢复“\(initialVoicePreset.title)”；尚未发送 Fn 或音频。"
                : "未联动语音软件快捷键。"
        }
        let configURL: URL
        if let i = arguments.firstIndex(of: "--config-path"), arguments.indices.contains(i + 1),
           arguments[i + 1].hasPrefix("/") {
            configURL = URL(fileURLWithPath: arguments[i + 1])
        } else if isPreview {
            configURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("preview-mappings.json")
        } else {
            configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenRemoteAssistant/mappings.json")
        }
        store = ConfigurationStore(url: configURL)
        bindingStore = DeviceBindingStore(url: configURL.deletingLastPathComponent()
            .appendingPathComponent(isPreview ? "preview-device-binding.json" : "device-binding.json"))
        do {
            bindings = try store.load()
            if FileManager.default.fileExists(atPath: configURL.path) { saveStatus = "已载入本地配置" }
        } catch {
            storageHealthy = false
            saveStatus = "配置读取失败 · 原文件保留"
            statusText = error.localizedDescription
        }
        if !isPreview {
            do {
                deviceBinding = try bindingStore.load()
                isDeviceBound = deviceBinding != nil
                if let binding = deviceBinding {
                    deviceSetupStatus = binding.hid == nil ? "已保存 RC003-MS 语音绑定；按键需先授权，再重新绑定。" :
                        "已保存 RC003-MS 绑定 · 固件 \(binding.identity.firmware) · 启用时重新核验"
                }
            } catch {
                bindingStorageHealthy = false
                deviceSetupStatus = "绑定读取失败，原文件未改动：\(error.localizedDescription)"
            }
        }
        isSetupExpanded = !isDeviceBound
        engine.configureTarget(deviceBinding)
        voice.configureTarget(deviceBinding)
        engine.onRequestBridgeStop = { [weak self] in self?.hidSession.stop() }
        hidSession.onChange = { [weak self] phase, message in
            guard let self else { return }
            let wasStopping = self.isMappingStopping
            self.isMappingStarting = phase == .validating || phase == .authorizing
            self.isMappingStopping = phase == .stopping
            self.mappingSessionStatus = phase == .idle ? "" : message
            if phase == .idle, self.hidServiceSessionVerified {
                self.hidServiceSessionVerified = false
                self.hidServiceInputPermissionText = "用户侧输入监控已允许；管理员接管会在下次启用映射时重新验证。"
            }
            if phase == .idle, wasStopping, !self.showActivationAlert, !self.isMappingEnabled {
                self.statusText = "映射未启用；按键辅助进程已结束，遥控器交回系统处理。"
            }
        }
        hidSession.onReady = { [weak self] target in
            guard let self else { return }
            guard !self.audioServiceActionsBlocked, !self.isPreparingToQuit, !self.isLaunchingUninstaller, !self.isRecording,
                  let bound = self.deviceBinding?.hid,
                  bound.registryID == target.registryID, bound.locationID == target.locationID else {
                self.hidSession.stop(message: "设备绑定或操作状态已改变；已取消启用映射。"); return
            }
            guard self.engine.enableFromBridge(mappings: self.engineMappings, target: bound) else {
                self.hidSession.stop(); self.activationProblem(self.engine.status.message); return
            }
            self.hidServiceInputPermission = .granted
            self.hidServiceRootAccessDenied = false
            self.hidServiceSessionVerified = true
            self.hidServiceInputPermissionText = "本次按键会话已实际通过输入访问并接管所选遥控器；停止后仍会在下次启用前重新核验。"
            self.hidInputAccessLastChecked = ProcessInfo.processInfo.systemUptime
            self.updateVoiceConnection()
        }
        hidSession.onKeys = { [weak self] usages in self?.engine.receiveBridgeUsages(usages) }
        hidSession.onStopped = { [weak self] message in self?.engine.bridgeDidStop(message) }
        hidSession.onFailure = { [weak self] message in
            guard let self, !self.isPreparingToQuit, !self.isLaunchingUninstaller else { return }
            self.activationProblem(message)
        }
        hidSession.onSessionFailure = { [weak self] code, message in
            guard let self, !self.isPreparingToQuit, !self.isLaunchingUninstaller else { return }
            if let permissionState = HIDServiceInputPermissionState.fromSessionFailure(code: code) {
                self.hidInputAccessGeneration &+= 1
                self.hidInputAccessLastChecked = ProcessInfo.processInfo.systemUptime
                self.hidServiceInputPermission = permissionState
                self.hidServiceSessionVerified = false
                self.hidServiceRootAccessDenied = true
                self.hidServiceInputPermissionText = "独立按键服务已在管理员接管阶段被 macOS 拒绝输入访问。用户侧绿勾不能覆盖这次实际失败；如再次授权后仍失败，当前开发版将保持映射关闭。"
                self.isSetupExpanded = true
                self.activationProblem(message
                    + "\n请先确认输入监控列表中已允许“遥控器按键服务”，再明确点击“刷新权限状态”后重试。"
                    + "\n如果用户侧显示已允许、下一次管理员接管仍被拒绝，说明当前开发版的服务身份路径未被这台 Mac 接受；程序会继续保持映射关闭，不会循环请求管理员授权。",
                                       offersInputMonitoringSettings: true)
            } else {
                self.activationProblem(message)
            }
        }
        engine.onStatus = { [weak self] state in
            guard let self else { return }
            let wasEnabled = self.isMappingEnabled
            self.isMappingEnabled = state.isEnabled
            self.connectionText = state.deviceConnected ? "所选 RC003-MS 按键通道在线" :
                (self.isDeviceBound ? "RC003-MS 已绑定 · 按键通道未就绪" : "请先绑定遥控器")
            if self.storageHealthy && !self.isRecording && !self.audioServiceActionsBlocked { self.statusText = state.message }
            if wasEnabled && !state.isEnabled {
                DispatchQueue.main.async { [weak self] in self?.updateVoiceConnection() }
            }
        }
        engine.onInput = { [weak self] usages in
            guard let self else { return }
            self.highlightTimeout?.cancel()
            if let button = RemoteButton.allCases.first(where: { $0.canMap && usages.contains($0.usage) }) {
                self.lastPressedButtonID = button.id
            }
            let clear = DispatchWorkItem { [weak self] in self?.lastPressedButtonID = nil }
            self.highlightTimeout = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: clear)
        }
        voice.onStatus = { [weak self] state in
            guard let self else { return }
            let becameReady = state.isReady && !self.voiceConnectionReady
            self.isVoiceEnabled = state.isEnabled
            // Keep the device picker locked while a requested audio session
            // safely replaces its previous BLE session (up to 350 ms).
            self.audioRoutingEnabled = self.audioRoutingRequested && (state.isEnabled || state.isRestarting)
            self.voiceStatusText = state.message
            self.voiceConnectionReady = state.isReady && state.audioDeviceUID != nil
            self.voiceIsStreaming = state.isStreaming
            self.voiceHasReceivedAudio = state.hasReceivedAudio
            self.voiceAudioFrames = state.audioFrames
            if !state.isEnabled {
                self.engine.setVoiceButtonPressed(false)
                if !state.isRestarting {
                    self.voiceConnectionParameters = nil
                    self.voiceRequested = false
                    self.audioRoutingRequested = false
                    self.voiceLevel = 0
                }
            }
            if becameReady, self.voiceShortcutEnabled {
                self.reconcileVoiceShortcut(resetRecovery: true)
            }
        }
        voice.onVoiceButton = { [weak self] down in
            guard let self else { return }
            // A voice preset owns the software Fn. Forwarding the same GATT
            // edge to the ordinary mapper would create a duplicate shortcut.
            if self.voiceShortcutEnabled {
                self.engine.setVoiceButtonPressed(false)
            } else {
                self.engine.setVoiceButtonPressed(down)
            }
            if down { self.lastPressedButtonID = RemoteButton.microphone.id }
            else if self.lastPressedButtonID == RemoteButton.microphone.id { self.lastPressedButtonID = nil }
        }
        voice.onVoiceShortcutFailure = { [weak self] failure in
            self?.handleVoiceShortcutFailure(failure)
        }
        voice.validateVoiceShortcutBeforeActivation = { [weak self] in
            guard let self, self.voiceShortcutEnabled else { return false }
            // HID services can disappear and be recreated while Bluetooth
            // remains connected. Reapply and verify the full transaction for
            // the bound physical location before every software Fn tap.
            self.reconcileVoiceShortcut(resetRecovery: false, forceApply: true)
            return self.voiceShortcutActive
        }
        voice.onLevel = { [weak self] level in self?.voiceLevel = level }
        voice.onDiscovery = { [weak self] candidates, message in
            guard let self else { return }
            self.isSearchingDevices = false
            self.discoveredDevices = candidates
            self.deviceChoices = candidates.map {
                SetupDeviceChoice(id: $0.id, title: "\($0.identity.model) · \($0.name)",
                    detail: "硬件 \($0.identity.hardware) · 固件 \($0.identity.firmware) · 软件 \($0.identity.software)",
                    isSupported: $0.profileID == DeviceProfile.rc003MS.id)
            }
            self.selectedDeviceChoiceID = candidates.count == 1 ? candidates[0].id : ""
            self.confirmSingleRemote = false
            self.deviceSetupStatus = message
        }
        appInactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.cancelRecording() }
        appActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshPermissionStatusAfterActivation() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] _ in self?.stopAll() })
        }
        configureAudioServiceReload(arguments: arguments)
        refreshStatus()
        if voiceShortcutEnabled { reconcileVoiceShortcut(resetRecovery: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func searchDevices() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview else {
            deviceSetupStatus = "界面预览不连接蓝牙，也不执行设备绑定。"; return
        }
        guard bindingStorageHealthy else {
            deviceSetupStatus = "请先处理绑定文件错误，原文件不会被覆盖。"; return
        }
        stopAll()
        discoveredDevices = []; deviceChoices = []; selectedDeviceChoiceID = ""
        isSearchingDevices = true
        deviceSetupStatus = "正在核验已连接设备的型号与能力，不订阅声音。"
        voice.discoverConnectedDevices()
    }

    func bindSelectedDevice() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview, bindingStorageHealthy, !isSearchingDevices else { return }
        guard confirmSingleRemote, discoveredDevices.count == 1,
              let candidate = discoveredDevices.first(where: { $0.id == selectedDeviceChoiceID }) else {
            deviceSetupStatus = "请只连接一只支持的遥控器，查找后确认手中的设备。"; return
        }
        let hid = MappingEngine.availableDevices()
        guard hid.count <= 1 else {
            deviceSetupStatus = "检测到多个同类按键设备，无法证明按键与声音来自同一只；请断开其他遥控器。"; return
        }
        let physicalConfirmation = confirmSingleRemote
        stopAll()
        restoreVoiceShortcutMappingForDeviceChange()
        do {
            let binding = try DeviceBinding.confirm(candidate: candidate, hid: hid.first,
                physicalConfirmation: physicalConfirmation)
            try bindingStore.save(binding)
            deviceBinding = binding
            engine.configureTarget(binding); voice.configureTarget(binding)
            isDeviceBound = true
            deviceSetupStatus = hid.isEmpty ? "RC003-MS 语音设备已绑定；按键通道待授权后重新确认。" :
                "RC003-MS 已绑定 · 仅限这一只设备 · 固件 \(binding.identity.firmware)"
            confirmSingleRemote = false
            refreshStatus()
            if voiceShortcutEnabled { reconcileVoiceShortcut(resetRecovery: true, forceApply: true) }
        } catch {
            deviceSetupStatus = "绑定未保存：\(error.localizedDescription)"
        }
    }

    func forgetDeviceBinding() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview, bindingStorageHealthy else { return }
        stopAll()
        restoreVoiceShortcutMappingForDeviceChange()
        do {
            try bindingStore.clear()
            deviceBinding = nil; isDeviceBound = false
            engine.configureTarget(nil); voice.configureTarget(nil)
            discoveredDevices = []; deviceChoices = []; selectedDeviceChoiceID = ""
            deviceSetupStatus = "旧绑定已解除，按键方案保留。请只连接一只遥控器后重新查找。"
            isSetupExpanded = true
            refreshStatus()
        } catch { deviceSetupStatus = "原绑定未删除：\(error.localizedDescription)" }
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    func importMappings() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard storageHealthy else { activationProblem("请先处理当前配置错误，不能覆盖原文件。"); return }
        stopAll()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "导入按键方案（不会导入设备身份或改动原文件）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let actions = try store.importActions(from: url)
            try store.save(actions)
            bindings = actions
            saveStatus = "已导入按键方案 · 原文件保留 · 映射保持关闭"
        } catch { activationProblem("导入失败：\(error.localizedDescription)") }
    }

    func select(_ button: RemoteButton) {
        cancelRecording()
        selectedButton = button
    }
    func bindingTitle(for button: RemoteButton) -> String {
        button.canMap ? (bindings[button.id]?.display ?? "未配置") : "待验证 · 不映射"
    }
    private var engineMappings: [UInt16: MappingAction] {
        Dictionary(uniqueKeysWithValues: RemoteButton.allCases.filter(\.canMap).map {
            ($0.usage, bindings[$0.id] ?? .disabled)
        })
    }
    private func commit(_ action: MappingAction, for button: RemoteButton) {
        guard button.canMap, action.isValid, storageHealthy else { return }
        var proposed = bindings
        proposed[button.id] = action
        do {
            try store.save(proposed)
            bindings = proposed
            saveStatus = "已自动保存到本机"
            if isMappingEnabled { engine.updateMappings(engineMappings); updateVoiceConnection() }
        } catch {
            stopAll()
            storageHealthy = false
            saveStatus = "保存失败 · 未应用修改"
            statusText = error.localizedDescription
        }
    }
    func setPreset(_ id: String, for button: RemoteButton) {
        cancelRecording()
        if let preset = KeyPreset.all.first(where: { $0.id == id }) { commit(preset.action, for: button) }
    }
    func clearBinding(for button: RemoteButton) { cancelRecording(); commit(.disabled, for: button) }
    func resetBinding(for button: RemoteButton) {
        cancelRecording()
        if let action = MappingDefaults.bindings[button.id] { commit(action, for: button) }
    }
    func toggleMapping() {
        if isMappingEnabled { stopMapping(); return }
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else {
            statusText = "音频服务操作尚未结束，暂不能启用映射。"; return
        }
        cancelRecording()
        guard !isPreview else { activationProblem("界面预览模式：不会接管遥控器或发送按键。"); return }
        guard storageHealthy else { activationProblem("请先解决配置文件问题，再启用映射。\n\(statusText)"); return }
        guard isDeviceBound, deviceBinding?.hid != nil else {
            isSetupExpanded = true
            activationProblem("请先在“按键映射权限与连接”中完成授权，再到设备设置重新绑定按键通道。只用麦克风不需要这些权限。"); return
        }
        refreshStatus()
        guard inputMonitoringGranted && accessibilityGranted else {
            let missing = [inputMonitoringGranted ? nil : "输入监控", accessibilityGranted ? nil : "辅助功能"].compactMap { $0 }.joined(separator: "、")
            activationProblem("主程序尚未获得：\(missing)。\n请在“按键映射权限与连接”中为当前“遥控器助手”完成对应授权，再返回并刷新状态。\n只给终端或旧版本授权，可能不适用于当前应用。",
                              offersInputMonitoringSettings: !inputMonitoringGranted)
            isSetupExpanded = true
            return
        }
        activationError = ""
        activationOffersInputMonitoringSettings = false
        engine.enable(mappings: engineMappings)
        if !engine.status.isEnabled { activationProblem(engine.status.message) }
        updateVoiceConnection()
    }
    private func activationProblem(_ message: String, offersInputMonitoringSettings: Bool = false) {
        activationError = message
        activationOffersInputMonitoringSettings = offersInputMonitoringSettings
        statusText = message.components(separatedBy: "\n").first ?? message
        showActivationAlert = true
    }
    func stopMapping() { cancelRecording(); engine.disable(); hidSession.stop(); updateVoiceConnection() }
    func stopAll() {
        cancelRecording()
        cancelPendingAudioRoutingStart()
        voiceRequested = false
        audioRoutingRequested = false
        audioRoutingEnabled = false
        voiceLevel = 0
        voiceConnectionParameters = nil
        voice.disable()
        engine.disable()
        hidSession.stop()
        isSearchingDevices = false
    }
    func refreshStatus() {
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        accessibilityGranted = AXIsProcessTrusted()
        if isPreview {
            connectionText = "界面预览 · 未接管设备"
        } else {
            engine.refreshConnectionStatus()
            connectionText = engine.status.deviceConnected ? "所选 RC003-MS 按键通道在线" :
                (isDeviceBound ? "RC003-MS 已绑定 · 按键通道未就绪" : "请先绑定遥控器")
        }
        refreshVoiceDevices()
        retryPendingVoiceShortcutRestoration()
    }
    func refreshPermissionStatus() {
        refreshPermissionStatus(userInitiated: true)
    }
    private func refreshPermissionStatusAfterActivation() {
        refreshPermissionStatus(userInitiated: false)
        typelessInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "now.typeless.desktop") != nil
        if voiceShortcutEnabled {
            reconcileVoiceShortcut(resetRecovery: true, forceApply: true)
        }
    }
    private func refreshPermissionStatus(userInitiated: Bool) {
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        accessibilityGranted = AXIsProcessTrusted()
        hidServiceInputPermission = .unknown
        hidServiceInputPermissionText = "当前版本使用主程序共享读取，不再启动独立按键服务。"
        hidServiceRootAccessDenied = false
    }
    func requestInputMonitoring() {
        guard !isPreview, !audioServiceActionsBlocked else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    func requestAccessibility() {
        guard !isPreview, !audioServiceActionsBlocked else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func setVoiceInputPreset(_ preset: VoiceInputPreset) {
        guard canChangeVoiceInputPreset, preset != voiceInputPreset else { return }
        typelessInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "now.typeless.desktop") != nil
        if preset != .off {
            guard audioDriverReady else {
                voiceShortcutStatus = "请先让遥控器麦克风组件完成加载，再选择语音软件。"
                return
            }
            guard deviceBinding?.hid?.isValid == true else {
                voiceShortcutStatus = "当前绑定缺少已确认的 RC003-MS 按键通道；请重新绑定遥控器。"
                return
            }
            accessibilityGranted = AXIsProcessTrusted()
            guard accessibilityGranted else {
                voiceShortcutStatus = "发送软件 Fn 需要辅助功能权限；授权后请重新选择语音软件。"
                requestAccessibility()
                return
            }
            voiceInputPreset = preset
            UserDefaults.standard.set(preset.rawValue, forKey: Self.voiceInputPresetPreferenceKey)
            UserDefaults.standard.set(false, forKey: Self.legacyTypelessPreferenceKey)
            isChangingVoiceShortcut = true
            voiceShortcutStatus = "正在准备“\(preset.title)”并中和遥控器物理 F5；尚未发送 Fn 或音频。"
            reconcileVoiceShortcut(resetRecovery: true, forceApply: true)
        } else {
            voiceInputPreset = .off
            UserDefaults.standard.set(preset.rawValue, forKey: Self.voiceInputPresetPreferenceKey)
            UserDefaults.standard.set(false, forKey: Self.legacyTypelessPreferenceKey)
            disableVoiceShortcut(status: "语音快捷键联动已关闭；遥控器语音键已恢复原映射。")
        }
    }

    private func reconcileVoiceShortcut(resetRecovery: Bool, forceApply: Bool = false) {
        guard voiceShortcutEnabled, !isPreview, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        if resetRecovery {
            voiceShortcutRecoveryWork?.cancel()
            voiceShortcutRecoveryWork = nil
            voiceShortcutRecoveryAttempt = 0
        }
        if voiceShortcutActive && !forceApply {
            isChangingVoiceShortcut = false
            return
        }
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            pauseVoiceShortcutRuntime(
                status: "辅助功能权限不可用；语音快捷键联动已暂停，未发送 Fn。"
            )
            return
        }
        guard audioDriverReady else {
            pauseVoiceShortcutRuntime(
                status: "音频组件尚未就绪；语音软件预设已保留，运行保持暂停。"
            )
            return
        }
        guard let rawLocation = deviceBinding?.hid?.locationID,
              let locationID = UInt32(exactly: rawLocation) else {
            pauseVoiceShortcutRuntime(
                status: "遥控器按键身份尚未绑定；语音软件预设已保留，运行保持暂停。"
            )
            return
        }

        let applied = voiceFunctionMapper.apply(neutralizeVoiceKey: true, targetLocationID: locationID)
        if applied && voiceFunctionMapper.isVoiceKeyNeutralized {
            voiceShortcutRecoveryWork?.cancel()
            voiceShortcutRecoveryWork = nil
            voiceShortcutRecoveryAttempt = 0
            voiceShortcutActive = true
            voice.setVoiceShortcutBehavior(voiceInputPreset.behavior)
            isChangingVoiceShortcut = false
            voiceShortcutStatus = "已就绪：\(voiceInputPreset.detail)"
            return
        }

        voiceShortcutActive = false
        if !voiceFunctionMapper.hasMatchingServices {
            pauseVoiceShortcutRuntime(
                status: "尚未枚举到已绑定遥控器的按键服务；语音软件预设已保留。"
            ) { [weak self] in
                self?.scheduleVoiceShortcutRecovery()
            }
            return
        }
        // A matching physical target was present but the transaction did not
        // complete. The mapper already rolled back all writes; do not leave a
        // preference that suggests the physical F5 has been neutralized.
        voiceInputPreset = .off
        UserDefaults.standard.set(VoiceInputPreset.off.rawValue, forKey: Self.voiceInputPresetPreferenceKey)
        pauseVoiceShortcutRuntime(
            status: "检测到 RC003-MS，但无法完整中和它的语音键；已回滚并关闭语音快捷键联动。"
        )
    }

    private func scheduleVoiceShortcutRecovery() {
        guard voiceShortcutEnabled, voiceShortcutRecoveryWork == nil else { return }
        guard voiceShortcutRecoveryAttempt < Self.voiceShortcutRecoveryDelays.count else {
            voiceShortcutStatus = "仍未枚举到已绑定遥控器的按键服务；偏好已保留。请唤醒遥控器后重新打开本程序。"
            return
        }
        let delay = Self.voiceShortcutRecoveryDelays[voiceShortcutRecoveryAttempt]
        voiceShortcutRecoveryAttempt += 1
        voiceShortcutStatus = "尚未枚举到已绑定遥控器的按键服务；将在 \(delay.formatted()) 秒后重试（\(voiceShortcutRecoveryAttempt)/\(Self.voiceShortcutRecoveryDelays.count)）。"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.voiceShortcutRecoveryWork = nil
            self.reconcileVoiceShortcut(resetRecovery: false)
        }
        voiceShortcutRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func disableVoiceShortcut(status: String) {
        voiceShortcutRecoveryWork?.cancel()
        voiceShortcutRecoveryWork = nil
        voiceShortcutRecoveryAttempt = 0
        isChangingVoiceShortcut = true
        voice.setVoiceShortcutBehavior(.off) { [weak self] in
            guard let self else { return }
            let restored = self.voiceFunctionMapper.restore()
            self.voiceShortcutActive = false
            self.isChangingVoiceShortcut = false
            self.voiceShortcutStatus = self.voiceShortcutStatusAfterRestore(
                success: status,
                restored: restored
            )
            self.engine.setVoiceButtonPressed(false)
        }
    }

    /// Used when an automatic prerequisite check fails. Stop the BLE/audio
    /// session first so no later frame can escape through the ordinary route,
    /// then let the Fn controller converge before restoring physical F5.
    private func pauseVoiceShortcutRuntime(status: String, completion: (() -> Void)? = nil) {
        isChangingVoiceShortcut = true
        voiceShortcutActive = false
        voice.disable { [weak self] in
            guard let self else { return }
            self.voice.setVoiceShortcutBehavior(.off) { [weak self] in
                guard let self else { return }
                let restored = self.voiceFunctionMapper.restore()
                self.isChangingVoiceShortcut = false
                self.voiceShortcutStatus = self.voiceShortcutStatusAfterRestore(
                    success: status,
                    restored: restored
                )
                self.engine.setVoiceButtonPressed(false)
                completion?()
            }
        }
    }

    private func voiceShortcutStatusAfterRestore(success: String, restored: Bool) -> String {
        guard !restored else { return success }
        return "软件 Fn 已停止，但遥控器语音键原映射尚未确认写回。请保持遥控器在线；程序会继续重试，退出前也会再次检查。"
    }

    private func retryPendingVoiceShortcutRestoration() {
        guard !voiceShortcutActive, !isChangingVoiceShortcut,
              voiceFunctionMapper.hasPendingRestoration else { return }
        let restored = voiceFunctionMapper.restore()
        if restored, !voiceShortcutEnabled {
            voiceShortcutStatus = "语音快捷键联动未启用；遥控器语音键原映射已恢复。"
        } else if !restored, !voiceShortcutEnabled {
            voiceShortcutStatus = voiceShortcutStatusAfterRestore(success: "", restored: false)
        }
    }

    private func handleVoiceShortcutFailure(_ failure: VoiceFnTapFailure) {
        voiceInputPreset = .off
        UserDefaults.standard.set(VoiceInputPreset.off.rawValue, forKey: Self.voiceInputPresetPreferenceKey)
        disableVoiceShortcut(status: "Fn \(failure.stageDescription)失败；已关闭语音快捷键联动并恢复遥控器原映射。")
    }

    private func restoreVoiceShortcutMappingForDeviceChange() {
        voiceShortcutRecoveryWork?.cancel()
        voiceShortcutRecoveryWork = nil
        voice.setVoiceShortcutBehavior(.off)
        let restored = voiceFunctionMapper.restore()
        voiceShortcutActive = false
        isChangingVoiceShortcut = false
        if voiceShortcutEnabled {
            voiceShortcutStatus = voiceShortcutStatusAfterRestore(
                success: "设备绑定已改变；语音软件预设保留，等待新遥控器完成按键中和。",
                restored: restored
            )
        }
    }
    func openInputMonitoringSettings() {
        guard !isPreview else {
            statusText = "界面预览不会打开或修改系统输入监控设置。"
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func openAccessibilitySettings() {
        guard !isPreview else {
            statusText = "界面预览不会打开或修改系统辅助功能设置。"
            return
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestHIDServiceInputAccess() {
        guard canRequestHIDServiceInputAccess else {
            if isPreview { hidServiceInputPermissionText = "界面预览不会启动按键服务或请求系统权限。" }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "为遥控器按键服务请求输入监控？"
        alert.informativeText = "这会通过 macOS LaunchServices 独立启动完整安装包内固定且已校验的“遥控器按键服务”，只请求该服务自己的输入监控权限。"
            + "\n本步骤不请求管理员权限、不接管遥控器，也不读取电脑键盘或音频。"
            + "\n请求结束后请根据这里显示的结果，另行决定是否打开系统设置。"
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "继续请求")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard canRequestHIDServiceInputAccess else { return }
        clearRootDenialForExplicitRetry()
        beginHIDServiceInputAccess(request: true)
    }

    private func checkHIDServiceInputAccess(force: Bool, userInitiated: Bool) {
        if isPreview {
            let state = HIDServiceInputPermissionState.preview(arguments: ProcessInfo.processInfo.arguments,
                plistValue: Bundle.main.object(forInfoDictionaryKey: "HIDInputAccessPreviewState") as? String)
            hidServiceInputPermission = state
            switch state {
            case .checking: hidServiceInputPermissionText = "界面预览：正在检查遥控器按键服务权限。不会通过 LaunchServices 启动辅助进程。"
            case .granted: hidServiceInputPermissionText = "界面预览：模拟按键服务输入监控已授权；未实际核验或接管设备。"
            case .denied: hidServiceInputPermissionText = "界面预览：模拟按键服务输入监控未授权；不会请求或打开系统设置。"
            case .unknown: hidServiceInputPermissionText = "界面预览：模拟按键服务权限尚未确认；不会启动辅助进程。"
            }
            return
        }
        guard HIDServicePermissionRefreshPolicy.permitsCheck(rootSessionDenied: hidServiceRootAccessDenied,
                                                              userInitiated: userInitiated) else { return }
        guard !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !hidSession.isRunning else { return }
        guard !hidSession.isCheckingInputAccess else {
            hidServiceInputPermission = .checking
            hidServiceInputPermissionText = "正在通过 LaunchServices 独立启动“遥控器按键服务”并检查它自己的输入监控权限；尚未接管遥控器。"
            return
        }
        // The two-second status timer must not launch a background helper over
        // and over.  Do one read-only check when the app starts; later checks
        // happen only after an app-activation transition or an explicit click.
        guard force || hidInputAccessLastChecked == 0 else { return }
        if userInitiated { clearRootDenialForExplicitRetry() }
        beginHIDServiceInputAccess(request: false)
    }

    private func clearRootDenialForExplicitRetry() {
        hidServiceRootAccessDenied = false
        hidServiceSessionVerified = false
    }

    private func beginHIDServiceInputAccess(request: Bool) {
        guard !isPreview, !isPreparingToQuit, !isLaunchingUninstaller,
              !hidSession.isRunning, !hidSession.isCheckingInputAccess else { return }
        hidInputAccessGeneration &+= 1
        let generation = hidInputAccessGeneration
        hidServiceInputPermission = .checking
        hidServiceInputPermissionText = request
            ? "正在通过 LaunchServices 独立启动“遥控器按键服务”并请求它自己的输入监控；尚未请求管理员授权或接管遥控器。"
            : "正在通过 LaunchServices 独立启动“遥控器按键服务”并检查它自己的输入监控权限；尚未接管遥控器。"
        let completion: (HIDInputAccessStatus, String) -> Void = { [weak self] status, message in
            guard let self, self.hidInputAccessGeneration == generation,
                  !self.isPreparingToQuit, !self.isLaunchingUninstaller, !self.isPreview else { return }
            self.hidInputAccessLastChecked = ProcessInfo.processInfo.systemUptime
            self.hidServiceInputPermission = .from(status)
            self.hidServiceSessionVerified = false
            self.hidServiceInputPermissionText = status == .granted
                ? "独立按键服务的用户侧输入监控已允许；管理员接管仍待下一次手动启用映射时实际验证。"
                : message
            if status != .granted { self.isSetupExpanded = true }
        }
        if request {
            hidSession.requestInputAccess(helperDigest: hidHelperDigest, completion: completion)
        } else {
            hidSession.checkInputAccess(helperDigest: hidHelperDigest, completion: completion)
        }
    }
    func refreshVoiceDevices(completion: (() -> Void)? = nil) {
        if isPreview {
            let availability = previewAudioReload?.availability ?? .missing
            applyAudioDriverReading(availability, devices: [])
            systemDefaultInputName = "界面预览不读取系统默认输入"
            completion?()
            return
        }
        let disposition = audioInspectionFlight.request()
        switch disposition {
        case .join:
            if let completion { audioInspectionCompletions.append(completion) }
            return
        case .completeFromTimedOutReading:
            // The five-second UI result has already failed closed. Do not put
            // another read on the serial queue while the original CoreAudio
            // call is still executing, and do not leave an explicit connect
            // action spinning while it waits for a call that may never return.
            completion?()
            return
        case .launch(let generation):
            if let completion { audioInspectionCompletions.append(completion) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.audioInspectionFlight.markTimedOut(generation: generation) else { return }
                let completions = self.takeAudioInspectionCompletions()
                self.applyAudioDriverReading(.unavailable("系统音频查询未及时返回；不会据此请求重载。"), devices: [])
                completions.forEach { $0() }
            }
            audioInspectionQueue.async { [weak self] in
                let reading = AudioDriverInstallation.read()
                let inputSnapshot = self?.systemDefaultInput.snapshot()
                DispatchQueue.main.async {
                    guard let self,
                          let result = self.audioInspectionFlight.finish(generation: generation) else { return }
                    let completions = result == .onTime ? self.takeAudioInspectionCompletions() : []
                    // A late result is still the newest completed catalog read,
                    // so it may refresh the display. Its waiters were already
                    // completed at timeout and must never be invoked twice.
                    self.applyAudioDriverReading(reading.availability, devices: reading.devices)
                    if let inputSnapshot { self.applySystemDefaultInputSnapshot(inputSnapshot) }
                    completions.forEach { $0() }
                }
            }
        }
    }

    private func takeAudioInspectionCompletions() -> [() -> Void] {
        let completions = audioInspectionCompletions
        audioInspectionCompletions.removeAll()
        return completions
    }

    private func applyAudioDriverReading(_ availability: AudioDriverAvailability, devices: [VoiceAudioDevice]) {
        let wasReady = audioDriverReady
        voiceOutputDevices = devices
        audioDriverReady = availability.isReady
        audioDriverNeedsReload = availability.needsReload
        audioDriverStatus = (isPreview ? "【预览模拟】" : "") + availability.message
        if !audioRoutingRequested && !devices.contains(where: { $0.uid == selectedVoiceOutputUID }) {
            selectedVoiceOutputUID = devices.first?.uid ?? ""
        }
        if availability == .ready, audioServiceReload?.phase == .verificationTimedOut {
            audioServiceReloadStatus = "上次请求的 25 秒验证窗口已结束；当前独立重新检查确认组件已生效。功能未自动恢复，尚未验证遥控器收音。"
        }
        if voiceShortcutEnabled,
           (voiceShortcutActive && !availability.isReady || (!voiceShortcutActive && !wasReady && availability.isReady)) {
            reconcileVoiceShortcut(resetRecovery: true, forceApply: true)
        }
    }

    private func applySystemDefaultInputSnapshot(_ snapshot: SystemDefaultInputSnapshot) {
        systemDefaultInputName = snapshot.currentName
        remoteMicrophoneIsSystemDefault = snapshot.remoteIsDefault
        remoteMicrophoneCanBecomeSystemDefault = snapshot.canSelectRemote
        canRestorePreviousSystemInput = snapshot.canRestorePrevious
        previousSystemInputName = snapshot.previousName ?? ""
    }

    func toggleSystemDefaultInput() {
        guard canChangeSystemDefaultInput else { return }
        if !remoteMicrophoneIsSystemDefault {
            let alert = NSAlert()
            alert.messageText = "将遥控器麦克风设为系统默认输入？"
            alert.informativeText = "这只影响系统默认麦克风，不改变扬声器或系统音效。所有跟随系统默认输入的录音、会议和浏览器程序都会改用它；已打开的软件可能仍需重新打开音频设置或重启。"
                + "\n未连接遥控器或停止说话时，该输入会保持静音。此系统设置在程序退出后仍会保留；程序会保存当前输入，只有你明确点击恢复或在退出提示中选择恢复时才改回。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "设为默认输入")
            alert.buttons.first?.keyEquivalent = "\r"
            alert.buttons.last?.keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let restore = remoteMicrophoneIsSystemDefault
        isChangingSystemDefaultInput = true
        systemDefaultInputStatus = restore ? "正在核对并恢复原默认输入。" : "正在核对并切换系统默认输入。"
        audioInspectionQueue.async { [weak self] in
            guard let self else { return }
            let message: String
            do {
                if restore {
                    switch try self.systemDefaultInput.restorePreviousInput() {
                    case .restored(let name): message = "已恢复系统默认输入：\(name)。"
                    case .nothingToRestore: message = "没有本程序保存的原默认输入；未更改系统设置。"
                    case .currentChanged(let name): message = "系统默认输入已改为“\(name)”；未覆盖这项新选择。"
                    case .previousUnavailable: message = "原默认输入当前不可用；未更改系统设置，请在声音设置中选择。"
                    }
                } else {
                    _ = try self.systemDefaultInput.selectRemoteInput()
                    message = "已设为系统默认输入；只跟随系统默认的程序现在会使用遥控器麦克风。"
                }
            } catch {
                message = error.localizedDescription
            }
            let snapshot = self.systemDefaultInput.snapshot()
            DispatchQueue.main.async {
                self.isChangingSystemDefaultInput = false
                guard !self.isPreparingToQuit else { return }
                self.applySystemDefaultInputSnapshot(snapshot)
                self.systemDefaultInputStatus = message
            }
        }
    }

    private func configureAudioServiceReload(arguments: [String]) {
        let executor: AudioServiceReloadExecuting
        if isPreview {
            let preview = PreviewAudioServiceReloadExecutor(availability: AudioDriverInstallation.previewState(arguments: arguments,
                plistValue: Bundle.main.object(forInfoDictionaryKey: "AudioDriverPreviewState") as? String),
                scenario: AudioReloadPreviewScenario.selected(arguments: arguments,
                    plistValue: Bundle.main.object(forInfoDictionaryKey: "AudioReloadPreviewScenario") as? String))
            previewAudioReload = preview
            executor = preview
        } else {
            executor = LiveAudioServiceReloadExecutor(
                helperSHA256: Bundle.main.object(forInfoDictionaryKey: "OpenRemoteAudioServiceHelperSHA256") as? String,
                inspect: { [weak self] completion in
                    guard let self else { return }
                    self.audioInspectionQueue.async {
                        let reading = AudioDriverInstallation.read()
                        DispatchQueue.main.async { completion(reading.availability) }
                    }
                }, stopOwnActivities: { [weak self] completion in
                    guard let self else { return }
                    self.stopAll()
                    self.voice.disable(completion: completion)
                })
        }
        let coordinator = AudioServiceReloadCoordinator(executor: executor)
        audioServiceReload = coordinator
        coordinator.onChange = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            self.isReloadingAudioService = coordinator.phase.isBusy
            self.audioServiceActionsBlocked = coordinator.phase.blocksActions
            self.audioServiceReloadBlocked = coordinator.phase.blocksReload
            self.canCheckAudioServiceRecovery = coordinator.phase == .unresolved
            self.isCheckingAudioServiceRecovery = coordinator.phase == .recovering
            self.audioServiceReloadStatus = coordinator.message
            if !coordinator.phase.isBusy { self.refreshVoiceDevices() }
        }
    }

    func requestAudioServiceReload() {
        guard !hidSession.isRunning else { activationProblem("请先停止映射或取消按键授权，并确认辅助进程结束后再重载音频服务。"); return }
        guard audioDriverNeedsReload, !audioServiceReloadBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isPreview ? "预览：重新加载音频服务？" : "重新加载整台电脑的音频服务？"
        alert.informativeText = "这会中断整台电脑所有应用的音频播放、麦克风、通话和会议。请先结束会议或录音。"
            + "\n本程序会先停止按键映射和遥控器语音，完成或失败后都不会自动恢复。"
            + "\n本程序不主动修改默认音频设备；macOS 或其他应用可能在设备重新出现时调整选择。"
            + (isPreview ? "\n当前仅为预览模拟，不会授权或操作任何系统服务。" : "\n下一步由 macOS 请求管理员授权。")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: isPreview ? "继续模拟" : "暂停本程序并重新加载")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard !audioServiceReloadBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        cancelRecording()
        audioServiceReload?.begin()
    }

    func confirmExitDuringAudioServiceReload() -> Bool {
        if isReloadingAudioService {
            let alert = NSAlert()
            alert.messageText = "音频服务操作尚未结束"
            alert.informativeText = "请先在系统授权提示中选择授权或取消，或等待端点检查结束。此时退出可能丢失操作结果。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return false
        }
        guard audioServiceReload?.phase == .unresolved else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "结果待确认，仍要退出？"
        alert.informativeText = "后台检查或重载请求可能仍在进行。退出不会停止它，也不代表请求已取消或完成；请勿重复发起重载。"
        alert.addButton(withTitle: "暂不退出")
        alert.addButton(withTitle: "我已了解，退出")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func toggleAudioRouting() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview else { voiceStatusText = "界面预览不会连接蓝牙或接收遥控器音频。"; return }
        if isAudioRoutingStarting {
            cancelPendingAudioRoutingStart()
            voiceStatusText = "已取消连接；未打开遥控器麦克风。"
            return
        }
        if audioRoutingRequested || audioRoutingEnabled {
            cancelPendingAudioRoutingStart()
            audioRoutingRequested = false
            audioRoutingEnabled = false
            voiceLevel = 0
            updateVoiceConnection()
            return
        }
        audioRoutingStartGeneration &+= 1
        let generation = audioRoutingStartGeneration
        isAudioRoutingStarting = true
        voiceStatusText = "正在重新检查专用音频端点；尚未连接遥控器或打开麦克风。"
        refreshVoiceDevices { [weak self] in self?.beginAudioRoutingAfterInspection(generation: generation) }
    }

    private func beginAudioRoutingAfterInspection(generation: UInt64) {
        guard generation == audioRoutingStartGeneration else { return }
        isAudioRoutingStarting = false
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller,
              !audioRoutingRequested, !audioRoutingEnabled else { return }
        guard voiceOutputDevices.filter({ $0.uid == selectedVoiceOutputUID }).count == 1 else {
            voiceStatusText = "专用麦克风组件未就绪；未连接遥控器、未开启麦克风。"
            return
        }
        guard isDeviceBound else { voiceStatusText = "请先查找并确认这一只遥控器。"; isSetupExpanded = true; return }
        audioRoutingRequested = true
        updateVoiceConnection()
    }

    private func cancelPendingAudioRoutingStart() {
        audioRoutingStartGeneration &+= 1
        isAudioRoutingStarting = false
    }
    func toggleVoice() {
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview else { voiceStatusText = "预览模式不连接蓝牙"; return }
        guard !audioRoutingRequested else {
            voiceStatusText = "语音键已随遥控器麦克风连接；关闭请使用“停止音频接入”。"
            return
        }
        if isVoiceEnabled {
            // An explicit disconnect also stops mappings that rely on this
            // button, preventing a apparently working voice binding.
            if isMappingEnabled && bindings[RemoteButton.microphone.id] != .disabled { engine.disable() }
            voiceRequested = false
            voiceConnectionParameters = nil
            voice.disable()
        } else {
            voiceRequested = true
            updateVoiceConnection()
        }
    }
    private func updateVoiceConnection() {
        guard !isPreview, !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        let needsButton = isMappingEnabled && bindings[RemoteButton.microphone.id] != .disabled
        guard voiceRequested || needsButton || audioRoutingRequested else {
            if voiceConnectionParameters != nil || isVoiceEnabled {
                voiceConnectionParameters = nil
                voice.disable()
            }
            return
        }
        let audioUID = audioRoutingRequested ? selectedVoiceOutputUID : nil
        if let audioUID, voiceOutputDevices.filter({ $0.uid == audioUID }).count != 1 {
            audioRoutingRequested = false
            audioRoutingEnabled = false
            voiceConnectionParameters = nil
            voice.disable()
            voiceStatusText = "专用麦克风组件不可用；音频已停止，不会改用电脑麦克风或扬声器。"
            return
        }
        guard let binding = deviceBinding else {
            voiceRequested = false; audioRoutingRequested = false; audioRoutingEnabled = false
            voiceStatusText = "请先绑定遥控器。"; isSetupExpanded = true; return
        }
        let parameters = "\(binding.id)|buttons|\(audioUID ?? "no-audio")"
        guard voiceConnectionParameters != parameters || !isVoiceEnabled else { return }
        // Reconfiguration may synchronously report its old session stopped.
        voiceConnectionParameters = parameters
        // Audio is opt-in and independent of keyboard takeover. An explicit
        // loopback UID receives only PCM from this remote, never a Mac input.
        voice.enable(buttonEvents: true, audioDeviceUID: audioUID)
    }
    func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
    func refreshAudioDriver() {
        // Explicit recovery only reads execution/process state. A normal
        // periodic catalog refresh can never clear an uncertain operation.
        if canCheckAudioServiceRecovery { audioServiceReload?.checkRecovery() }
        refreshVoiceDevices()
        if voiceShortcutEnabled { reconcileVoiceShortcut(resetRecovery: true, forceApply: true) }
    }
    func showInstallerHelp() {
        guard let readme = Bundle.main.url(forResource: "INSTALL", withExtension: "html") else {
            voiceStatusText = "请使用“遥控器助手”完整安装包安装或修复音频组件。安装后若尚未生效，可结束会议后主动重新加载音频服务；程序不会自动重载或重启。"; return
        }
        NSWorkspace.shared.open(readme)
    }
    func showOpenSourceLicense() {
        guard let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
            statusText = "未找到随应用附带的 GPLv3 许可文本；请使用同版本完整安装包修复。"
            return
        }
        NSWorkspace.shared.open(license)
    }
    func showUninstaller() {
        guard !hidSession.isRunning else { activationProblem("请先停止映射或取消启用，并确认按键辅助进程结束后再卸载。"); return }
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else {
            activationProblem("音频服务操作尚未结束或结果待确认，暂不能同时启动卸载。"); return
        }
        let alert = NSAlert()
        alert.messageText = "打开卸载界面？"
        alert.informativeText = "卸载界面打开后，遥控器助手会停止并退出。你仍需在卸载窗口再次确认，并通过系统管理员授权；个人设置默认保留。"
            + (isPreview ? "\n当前为预览模式：只演示此确认，不启动卸载程序。" : "")
        alert.addButton(withTitle: isPreview ? "确认预览" : "打开卸载界面")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        guard !isPreview else { statusText = "已演示卸载确认；预览不会启动卸载程序或删除文件。"; return }
        let uninstaller = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/卸载遥控器助手.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: uninstaller.appendingPathComponent("Contents/MacOS/OpenRemoteUninstaller").path) else {
            activationProblem("当前应用缺少内置卸载界面。请使用完整安装包修复后重试；未卸载任何内容。"); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        isLaunchingUninstaller = true
        NSWorkspace.shared.openApplication(at: uninstaller, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard application != nil, error == nil else {
                    self?.isLaunchingUninstaller = false
                    self?.activationProblem("无法打开卸载界面，主程序保持运行：\(error?.localizedDescription ?? "未知错误")")
                    return
                }
                self?.stopAll()
                NSApplication.shared.terminate(nil)
            }
        }
    }
    func showConfiguration() {
        if FileManager.default.fileExists(atPath: store.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        } else {
            statusText = "修改任一映射后会自动创建配置文件。"
        }
    }

    func startRecording(for button: RemoteButton) {
        guard button.canMap, storageHealthy, !audioServiceActionsBlocked, !isPreparingToQuit, !isLaunchingUninstaller else { return }
        cancelRecording()
        if hidSession.isRunning { stopMapping() }
        recordingFnHeld = false
        selectedButton = button
        recordedButton = button
        isRecording = true
        recordingHint = "请在 Mac 键盘上按目标键或组合键，Esc 取消。"
        statusText = "正在录入；映射已暂停，录入结束后请手动重新启用。"
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == MappingEngine.injectedEventMarker { return nil }
            if event.type == .flagsChanged {
                if event.keyCode == 63 {
                    let wasHeld = self.recordingFnHeld
                    self.recordingFnHeld = event.modifierFlags.contains(.function)
                    if wasHeld && !self.recordingFnHeld {
                        let selected = self.recordedButton
                        self.cancelRecording()
                        if let selected { self.commit(.modifier(flag: CGEventFlags.maskSecondaryFn.rawValue), for: selected) }
                        return nil
                    }
                }
                self.recordingHint = KeyNames.modifierLabel(event.modifierFlags) + " … 请再按一个目标键"
                return nil
            }
            if event.isARepeat { return nil }
            if event.keyCode == 53 { self.cancelRecording(); return nil }
            guard ![54,55,56,57,58,59,60,61,62,63].contains(event.keyCode), event.keyCode < 127 else { return nil }
            let keyCode = KeyNames.normalizedKeyCode(event)
            let flags = KeyNames.recordedModifiers(event, physicalFnHeld: self.recordingFnHeld)
            let label = KeyNames.modifierLabel(NSEvent.ModifierFlags(rawValue: UInt(flags))) + KeyNames.label(for: keyCode, event: event)
            let action = MappingAction.shortcut(KeyCombo(keyCode: keyCode, modifiers: flags, displayName: label))
            let selected = self.recordedButton
            self.cancelRecording()
            if let selected { self.commit(action, for: selected) }
            return nil
        }
        let timeout = DispatchWorkItem { [weak self] in self?.cancelRecording() }
        recordingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }
    func cancelRecording() {
        guard isRecording || localMonitor != nil else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        recordingTimeout?.cancel()
        recordingTimeout = nil
        recordedButton = nil
        recordingFnHeld = false
        isRecording = false
        recordingHint = ""
        statusText = "映射未启用；编辑完成后点击启用映射。"
    }
    func shutdown() {
        hidInputAccessGeneration &+= 1
        voiceShortcutRecoveryWork?.cancel()
        voiceShortcutRecoveryWork = nil
        cancelRecording()
        timer?.invalidate()
        if let appInactiveObserver { NotificationCenter.default.removeObserver(appInactiveObserver) }
        appInactiveObserver = nil
        if let appActiveObserver { NotificationCenter.default.removeObserver(appActiveObserver) }
        appActiveObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopAll()
        voice.setVoiceShortcutBehavior(.off)
        voiceFunctionMapper.restore()
        voiceShortcutActive = false
    }
    func prepareToQuit(completion: @escaping (Bool) -> Void) {
        guard !isChangingSystemDefaultInput else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "系统默认输入切换尚未确认"
            alert.informativeText = "请等待本次切换完成并检查结果后再退出，避免把状态未知的默认麦克风留给其他程序。"
            alert.addButton(withTitle: "返回等待")
            alert.runModal()
            completion(false)
            return
        }

        var restoreDefaultBeforeExit = false
        if remoteMicrophoneIsSystemDefault && canRestorePreviousSystemInput {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "退出前如何处理系统默认输入？"
            alert.informativeText = "遥控器音频会停止。如果保留“遥控器麦克风”为系统默认输入，只跟随默认输入的程序将保持静音，直到你再次连接或手动更改。"
            alert.addButton(withTitle: "恢复原输入并退出")
            alert.addButton(withTitle: "保留并退出")
            alert.addButton(withTitle: "取消退出")
            alert.buttons.first?.keyEquivalent = "\r"
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                restoreDefaultBeforeExit = true
            case .alertSecondButtonReturn:
                break
            default:
                completion(false)
                return
            }
        }

        isPreparingToQuit = true
        hidInputAccessGeneration &+= 1
        stopAll()
        var voiceStopped = false, hidStopped = false, defaultInputSettled = false
        var typelessMappingSettled = !voiceFunctionMapper.hasPendingRestoration
        var finished = false
        var watchdog: DispatchWorkItem?
        let finishIfReady = {
            if !typelessMappingSettled {
                typelessMappingSettled = !self.voiceFunctionMapper.hasPendingRestoration
            }
            guard TypelessQuitGate.canFinish(
                voiceStopped: voiceStopped,
                hidStopped: hidStopped,
                defaultInputSettled: defaultInputSettled,
                physicalKeyRestored: typelessMappingSettled
            ), !finished else { return }
            finished = true
            watchdog?.cancel()
            completion(true)
        }
        let cancelQuit: (String) -> Void = { [weak self] message in
            guard let self, !finished else { return }
            finished = true
            watchdog?.cancel()
            self.isChangingSystemDefaultInput = false
            self.isPreparingToQuit = false
            self.systemDefaultInputStatus = message
            self.refreshVoiceDevices()
            completion(false)
        }
        let scheduleWatchdog = { [weak self] in
            watchdog?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !finished else { return }
                if !typelessMappingSettled {
                    typelessMappingSettled = !self.voiceFunctionMapper.hasPendingRestoration
                }
                if TypelessQuitGate.canFinish(
                    voiceStopped: voiceStopped,
                    hidStopped: hidStopped,
                    defaultInputSettled: defaultInputSettled,
                    physicalKeyRestored: typelessMappingSettled
                ) {
                    finishIfReady()
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "后台停止状态尚待确认"
                alert.informativeText = "本程序已停止生成按键并断开本次通信，但还未确认辅助进程、语音服务或默认输入切换操作完全结束。"
                    + (typelessMappingSettled ? "" : "\n遥控器语音键原映射尚未确认写回；继续退出可能要等遥控器重连后才恢复。")
                    + "\n可以返回窗口检查状态。若仍有系统授权窗口，请取消；不要再次授权。"
                    + "\n选择退出不会把尚未确认的后台操作标记为成功。"
                alert.addButton(withTitle: "返回检查")
                alert.addButton(withTitle: "我已了解，退出")
                alert.buttons.first?.keyEquivalent = "\r"; alert.buttons.last?.keyEquivalent = ""
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                guard !finished else { return }
                finished = true
                if !shouldQuit { self.isPreparingToQuit = false }
                completion(shouldQuit)
            }
            watchdog = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
        }
        hidSession.whenStopped { hidStopped = true; finishIfReady() }
        voice.disable { [weak self] in
            guard let self else { return }
            self.voice.setVoiceShortcutBehavior(.off)
            typelessMappingSettled = self.voiceFunctionMapper.restore()
            self.voiceShortcutActive = false
            if !typelessMappingSettled {
                self.voiceShortcutStatus = self.voiceShortcutStatusAfterRestore(
                    success: "",
                    restored: false
                )
            }
            voiceStopped = true
            finishIfReady()
        }
        scheduleWatchdog()
        guard restoreDefaultBeforeExit else {
            // Queue behind any already-submitted explicit input operation. Quit
            // never changes the default silently when the user chose to keep it.
            audioInspectionQueue.async {
                DispatchQueue.main.async { defaultInputSettled = true; finishIfReady() }
            }
            return
        }
        isChangingSystemDefaultInput = true
        audioInspectionQueue.async { [weak self] in
            guard let self else { return }
            let outcome: Result<SystemDefaultInputRestoreResult, Error>
            do { outcome = .success(try self.systemDefaultInput.restorePreviousInput()) }
            catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                self.isChangingSystemDefaultInput = false
                guard !finished else { return }
                let failure: String?
                switch outcome {
                case .success(.restored(let name)):
                    self.systemDefaultInputStatus = "已恢复系统默认输入：\(name)。"
                    failure = nil
                case .success(.currentChanged(let name)):
                    self.systemDefaultInputStatus = "系统默认输入已改为“\(name)”；未再更改。"
                    failure = nil
                case .success(.nothingToRestore):
                    failure = "没有可恢复的原默认输入；未更改系统设置。"
                case .success(.previousUnavailable):
                    failure = "原默认输入当前不可用；未更改系统设置。"
                case .failure(let error):
                    failure = error.localizedDescription
                }
                guard let failure else {
                    defaultInputSettled = true
                    finishIfReady()
                    return
                }
                watchdog?.cancel()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "未能确认恢复原输入"
                alert.informativeText = failure + "\n遥控器音频已经停止。若仍要退出，请随后在系统声音设置中确认默认输入。"
                alert.addButton(withTitle: "返回检查")
                alert.addButton(withTitle: "保留当前输入并退出")
                alert.buttons.first?.keyEquivalent = "\r"; alert.buttons.last?.keyEquivalent = ""
                if alert.runModal() == .alertSecondButtonReturn {
                    defaultInputSettled = true
                    scheduleWatchdog()
                    finishIfReady()
                } else {
                    cancelQuit(failure)
                }
            }
        }
    }
}
