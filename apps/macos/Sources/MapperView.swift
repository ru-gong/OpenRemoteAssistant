import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum MapperColors {
    static let background = Color(red: 0.970, green: 0.974, blue: 0.982)
    static let ink = Color(red: 0.13, green: 0.16, blue: 0.22)
    static let muted = Color(red: 0.45, green: 0.49, blue: 0.55)
    static let accent = Color(red: 0.20, green: 0.40, blue: 0.91)
    static let line = Color(red: 0.88, green: 0.90, blue: 0.93)
    static let amber = Color(red: 0.70, green: 0.42, blue: 0.09)
    static let green = Color(red: 0.12, green: 0.56, blue: 0.38)
}

struct MapperView: View {
    @ObservedObject var model: MapperModel
    @StateObject private var photoStore: PhotoLayoutStore

    init(model: MapperModel) {
        self.model = model
        _photoStore = StateObject(wrappedValue: PhotoLayoutStore(rootURL:
            model.store.url.deletingLastPathComponent()
                .appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(DeviceProfile.rc003MS.id, isDirectory: true)
                .appendingPathComponent("remote-photo", isDirectory: true)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    if model.audioDriverNeedsReload || !model.audioServiceReloadStatus.isEmpty {
                        AudioActivationNotice(model: model)
                    }
                    DeviceSetupSection(model: model)
                        .disabled(model.audioServiceActionsBlocked)
                    HStack(alignment: .top, spacing: 24) {
                        RemotePhotoPanel(model: model, store: photoStore)
                            .frame(width: 260, height: 526)
                        VStack(alignment: .leading, spacing: 14) {
                            MappingList(model: model)
                            MappingEditor(model: model)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .disabled(model.isReloadingAudioService)
                    VoiceConnectionSection(model: model)
                    connectionSettings
                        .disabled(model.audioServiceActionsBlocked)
                }
                .padding(20)
            }
        }
        .foregroundStyle(MapperColors.ink)
        .background(.white)
        .frame(minWidth: 900, minHeight: 650)
        .preferredColorScheme(.light)
        .onAppear {
            model.refreshStatus()
            if photoStore.isCalibrating, let next = photoStore.nextUncalibratedButton { model.select(next) }
        }
        .alert("操作未完成", isPresented: $model.showActivationAlert) {
            if model.activationOffersInputMonitoringSettings {
                Button("稍后", role: .cancel) { }
                Button("打开输入监控设置", action: model.openInputMonitoringSettings)
            } else {
                Button("知道了", role: .cancel) { }
            }
        } message: {
            Text(model.activationError)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("遥控器助手")
                    .font(.system(size: 21, weight: .semibold))
                Text("RC003-MS  ·  \(model.saveStatus)")
                    .font(.system(size: 11))
                    .foregroundStyle(MapperColors.muted)
                    .lineLimit(1)
                    .help(model.saveStatus)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 12) {
                    Label(model.isMappingStarting ? "正在启用" : model.isMappingStopping ? "正在停止" : model.isMappingEnabled ? "映射已启用" : "映射未启用",
                          systemImage: model.isMappingEnabled ? "checkmark.circle.fill" : "pause.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.isMappingEnabled ? MapperColors.green : MapperColors.muted)
                    Button(action: model.toggleMapping) {
                        Text(model.isMappingStopping ? "检查停止状态" : model.isMappingStarting ? "取消启用" : model.isMappingEnabled ? "停止映射" : "启用映射")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minWidth: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isMappingEnabled ? Color.red : MapperColors.accent)
                    .controlSize(.large)
                    .disabled(!model.isMappingStarting && !model.isMappingStopping && (model.audioServiceActionsBlocked || model.isRecording || (!model.isDeviceBound && !model.isMappingEnabled)))
                    .help(model.isDeviceBound ? "使用主程序输入监控和辅助功能权限；优先独占，系统拒绝时共享读取并屏蔽对应原按键。不自动接入麦克风。" : "请先在下方选择并绑定遥控器。")
                }
                Text(model.isMappingStarting || model.isMappingStopping ? model.mappingSessionStatus : model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(model.isMappingEnabled ? MapperColors.muted : MapperColors.amber)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 440, alignment: .trailing)
                    .help(model.isMappingStarting || model.isMappingStopping ? model.mappingSessionStatus : model.statusText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var connectionSettings: some View {
        DisclosureGroup(isExpanded: $model.isSetupExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionStatus(title: "主程序输入监控", detail: "让遥控器助手识别本机按键权限状态。",
                                 granted: model.inputMonitoringGranted,
                                 request: model.requestInputMonitoring,
                                 openSettings: model.openInputMonitoringSettings)
                PermissionStatus(title: "主程序辅助功能", detail: "发送映射目标键，以及语音软件预设所需的软件 Fn。",
                                 granted: model.accessibilityGranted,
                                 request: model.requestAccessibility,
                                 openSettings: model.openAccessibilitySettings)
                Text("按键映射只使用上面两项主程序权限：共享读取已绑定的 RC003-MS，并屏蔽对应原按键后发送映射目标键。普通麦克风接入不需要这两项；语音软件预设只需要辅助功能来发送软件 Fn。")
                    .foregroundStyle(MapperColors.muted)
                HStack {
                    Text(model.connectionText).foregroundStyle(MapperColors.muted)
                    Spacer()
                    Button("刷新权限状态", action: model.refreshPermissionStatus).buttonStyle(.borderless)
                    Button("导入已有映射…", action: model.importMappings).buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11))
            .padding(.top, 12)
            .padding(.bottom, 4)
        } label: {
            HStack(spacing: 8) {
                Text("按键映射权限与连接")
                    .font(.system(size: 12, weight: .medium))
                if !model.mappingPermissionsReady {
                    Text("需要授权")
                        .font(.system(size: 10))
                        .foregroundStyle(MapperColors.amber)
                }
            }
        }
        .tint(MapperColors.muted)
        .padding(.top, 2)
    }
}

private struct DeviceSetupSection: View {
    @ObservedObject var model: MapperModel
    @State private var expanded = false
    @State private var confirmRebinding = false
    private var bindingAllowed: Bool {
        !model.isSearchingDevices && model.confirmSingleRemote && model.deviceChoices.count == 1
            && model.deviceChoices.contains { $0.id == model.selectedDeviceChoiceID && $0.isSupported }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(model.isDeviceBound ? "已绑定遥控器" : "首次设置 · 选择你的遥控器",
                      systemImage: model.isDeviceBound ? "checkmark.circle.fill" : "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.isDeviceBound ? MapperColors.green : MapperColors.ink)
                Spacer()
                if model.isDeviceBound {
                    Button(expanded ? "收起" : "设备设置") { expanded.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Text(model.deviceSetupStatus)
                .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isDeviceBound {
                Text("当前仅支持 RC003-MS（设备自报 RC003）。请先在 macOS 蓝牙设置中配对，并断开其他同类遥控器。")
                    .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                HStack(spacing: 12) {
                    Button("打开蓝牙设置", action: model.openBluetoothSettings).buttonStyle(.bordered)
                    Button(model.isSearchingDevices ? "正在查找…" : "查找已连接的遥控器", action: model.searchDevices)
                        .buttonStyle(.bordered).disabled(model.isSearchingDevices)
                    if model.isSearchingDevices {
                        ProgressView().controlSize(.small)
                        Button("取消查找", action: model.stopAll).buttonStyle(.borderless)
                    }
                    Spacer()
                }
                if !model.deviceChoices.isEmpty {
                    Picker("选择设备", selection: $model.selectedDeviceChoiceID) {
                        Text("请选择设备").tag("")
                        ForEach(model.deviceChoices) { choice in
                            Text(choice.title + (choice.isSupported ? "" : " · 暂不支持")).tag(choice.id)
                        }
                    }
                    .disabled(model.isSearchingDevices)
                    if let choice = model.deviceChoices.first(where: { $0.id == model.selectedDeviceChoiceID }) {
                        Text(choice.detail).font(.system(size: 10)).foregroundStyle(MapperColors.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("我已只连接这一只遥控器，并确认上面选的是手里的设备", isOn: $model.confirmSingleRemote)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .disabled(model.isSearchingDevices)
                    HStack(spacing: 12) {
                        Button("绑定这只遥控器", action: model.bindSelectedDevice)
                            .buttonStyle(.borderedProminent).tint(MapperColors.accent).disabled(!bindingAllowed)
                        Text(model.deviceChoices.count > 1
                             ? "检测到多个候选，请只保留一只后重新查找。"
                             : "绑定只保存设备选择，不启用映射或麦克风。")
                            .font(.system(size: 10)).foregroundStyle(MapperColors.muted)
                    }
                }
            } else if expanded {
                HStack(spacing: 12) {
                    Text("按键映射和麦克风接入都只使用这只设备。")
                        .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                    Spacer()
                    Button("重新绑定…") { confirmRebinding = true }.buttonStyle(.bordered)
                    Button("蓝牙设置", action: model.openBluetoothSettings).buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MapperColors.background, in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("重新绑定遥控器？", isPresented: $confirmRebinding, titleVisibility: .visible) {
            Button("停止全部并重新绑定", role: .destructive) { model.forgetDeviceBinding(); expanded = false }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将停止按键映射和麦克风连接。现有按键配置和照片会保留。")
        }
    }
}

private struct MappingList: View {
    @ObservedObject var model: MapperModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("遥控器按键").frame(width: 124, alignment: .leading)
                Text("映射为")
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MapperColors.muted)
            .padding(.horizontal, 11)
            .frame(height: 28)
            Divider()
            ForEach(RemoteButton.allCases) { button in
                MappingListRow(model: model, button: button)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(MapperColors.line, lineWidth: 1))
    }
}

private struct MappingListRow: View {
    @ObservedObject var model: MapperModel
    let button: RemoteButton
    private var selected: Bool { model.selectedButton == button }
    private var pressed: Bool { model.lastPressedButtonID == button.id }
    var body: some View {
        Button { model.select(button) } label: {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: button.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                    Text(button.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                }
                .frame(width: 124, alignment: .leading)
                Text(button.canMap ? model.bindingTitle(for: button) : "待验证")
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(button.canMap ? (selected ? MapperColors.accent : MapperColors.ink) : MapperColors.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if pressed {
                    Circle().fill(MapperColors.green).frame(width: 6, height: 6)
                } else if selected {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(MapperColors.accent)
                }
            }
            .foregroundStyle(button.canMap ? MapperColors.ink : MapperColors.muted)
            .padding(.horizontal, 11)
            .frame(height: 31)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pressed ? MapperColors.green.opacity(0.09) : selected ? MapperColors.accent.opacity(0.075) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(button.title) → \(button.canMap ? model.bindingTitle(for: button) : "输入待验证")")
        .accessibilityLabel("\(button.title)，\(button.canMap ? model.bindingTitle(for: button) : "待验证")，点击编辑")
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

private struct MappingEditor: View {
    @ObservedObject var model: MapperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: model.selectedButton.symbol)
                Text("编辑“\(model.selectedButton.title)”").fontWeight(.semibold)
                Spacer()
                if model.selectedButton.canMap {
                    Button("恢复默认") { model.resetBinding(for: model.selectedButton) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .foregroundStyle(MapperColors.muted).disabled(model.isRecording)
                }
            }
            .font(.system(size: 12))
            if model.selectedButton.canMap {
                HStack(spacing: 9) {
                    Menu {
                        ForEach(KeyPreset.all) { preset in
                            Button { model.setPreset(preset.id, for: model.selectedButton) } label: {
                                if model.bindings[model.selectedButton.id] == preset.action {
                                    Label(preset.title, systemImage: "checkmark")
                                } else { Text(preset.title) }
                            }
                        }
                    } label: {
                        Text(model.bindingTitle(for: model.selectedButton))
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderedButton).controlSize(.large)
                    .disabled(model.isRecording).frame(maxWidth: .infinity)
                    .help("选择常用按键或组合键")
                    Button {
                        if model.isRecording { model.cancelRecording() }
                        else { model.startRecording(for: model.selectedButton) }
                    } label: {
                        Label(model.isRecording ? "取消录入" : "键盘录入",
                              systemImage: model.isRecording ? "xmark" : "keyboard")
                            .font(.system(size: 12, weight: .medium)).frame(minWidth: 91)
                    }
                    .buttonStyle(.borderedProminent).tint(MapperColors.accent).controlSize(.large)
                    .disabled(model.audioServiceActionsBlocked)
                    .help(model.audioServiceActionsBlocked ? "请先在上方检查音频后台状态；仍可选择按键和常用映射。" : "按下目标键或组合键进行录入。")
                }
                editorHint
            } else {
                Text("\(model.selectedButton.title)键的独立输入尚未验证，暂不开放映射。")
                    .font(.system(size: 11)).foregroundStyle(MapperColors.muted).padding(.vertical, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MapperColors.background, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var editorHint: some View {
        if model.isRecording {
            Text(model.recordingHint).font(.system(size: 11)).foregroundStyle(MapperColors.accent).lineLimit(2)
        } else if model.bindings[model.selectedButton.id]?.usesSoftwareFn == true {
            Text("发送 macOS 软件 Fn 按下/释放事件；不是实体 Globe 键。目标软件需使用 Fn 快捷键。")
                .font(.system(size: 10)).foregroundStyle(MapperColors.amber).lineLimit(2)
        } else if model.selectedButton == .microphone {
            Text("可同时触发快捷键；音频接入后，按住说话、松开关闭。")
                .font(.system(size: 10)).foregroundStyle(MapperColors.muted)
        } else {
            Text("下拉选择常用键，或点击录入后按下目标组合键。")
                .font(.system(size: 10)).foregroundStyle(MapperColors.muted)
        }
    }
}

private struct AudioActivationNotice: View {
    @ObservedObject var model: MapperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(model.audioDriverReady ? "麦克风组件已生效" : "麦克风组件激活", systemImage: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if model.isReloadingAudioService { ProgressView().controlSize(.small) }
                if model.audioDriverNeedsReload {
                    Button("重新加载音频服务…", action: model.requestAudioServiceReload)
                        .buttonStyle(.borderedProminent).tint(MapperColors.accent)
                        .disabled(model.audioServiceReloadBlocked)
                }
                Button(model.isCheckingAudioServiceRecovery ? "正在检查后台状态…" :
                       model.canCheckAudioServiceRecovery ? "重新检查并恢复操作" : "重新检查",
                       action: model.refreshAudioDriver)
                    .buttonStyle(.borderless).disabled(model.isReloadingAudioService)
            }
            Text(model.audioServiceReloadStatus.isEmpty
                 ? "当前组件状态：" + model.audioDriverStatus
                 : (model.isReloadingAudioService ? "本次重载操作：" : "上次重载操作：")
                    + model.audioServiceReloadStatus + "\n当前组件状态：" + model.audioDriverStatus)
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if model.audioDriverNeedsReload && !model.audioServiceReloadBlocked {
                Text("安装不要求重启电脑。重新加载会暂时中断整台电脑的声音和录音；请先结束会议，再确认并授权，也可稍后处理。")
                    .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MapperColors.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct VoiceConnectionSection: View {
    @ObservedObject var model: MapperModel
    @State private var keyDetailsExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mic.fill").font(.system(size: 17)).foregroundStyle(MapperColors.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("遥控器麦克风").font(.system(size: 14, weight: .semibold))
                    Text(model.voiceStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(model.audioRoutingEnabled ? MapperColors.accent : MapperColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isAudioRoutingStarting { ProgressView().controlSize(.small) }
                Button(model.isAudioRoutingStarting ? "取消连接" :
                       model.audioRoutingEnabled ? "停止音频接入" : "连接遥控器麦克风",
                       action: model.toggleAudioRouting)
                    .buttonStyle(.borderedProminent)
                    .tint(model.audioRoutingEnabled || model.isAudioRoutingStarting ? Color.red : MapperColors.accent)
                    .controlSize(.large)
                    .disabled(model.audioServiceActionsBlocked ||
                              (!model.isAudioRoutingStarting && model.audioConnectionBlockedReason != nil && !model.audioRoutingEnabled))
                    .help(model.audioConnectionBlockedReason ?? "只接入遥控器麦克风，不主动更改系统默认输入或输出。")
            }
            HStack(spacing: 18) {
                Label(model.audioDriverReady ? "组件就绪" : "组件待检查", systemImage: model.audioDriverReady ? "checkmark.circle.fill" : "circle")
                Label(model.voiceConnectionReady ? "遥控器已连接" : "遥控器未连接", systemImage: model.voiceConnectionReady ? "checkmark.circle.fill" : "circle")
                Label(model.voiceHasReceivedAudio ? (model.voiceIsStreaming ? "正在送入声音" : "本次已收到音频") : "尚未收到音频",
                      systemImage: model.voiceHasReceivedAudio ? "waveform" : "circle")
            }
            .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
            if let reason = model.audioConnectionBlockedReason, !model.audioRoutingEnabled {
                Text(reason).font(.system(size: 11)).foregroundStyle(MapperColors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("无需启用按键映射。连接后按住右上角语音键说话，松开停止；不做转写。")
                .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text("语音软件")
                        .fontWeight(.medium)
                    Picker("语音软件", selection: Binding(
                        get: { model.voiceInputPreset },
                        set: { model.setVoiceInputPreset($0) }
                    )) {
                        ForEach(VoiceInputPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .disabled(!model.canChangeVoiceInputPreset)
                    Spacer(minLength: 8)
                    Label(model.voiceShortcutActive ? model.voiceInputPreset.readinessTitle :
                          model.voiceShortcutRestorationPending ? "等待恢复原映射" :
                          model.voiceShortcutEnabled ? "等待语音键中和" : "未启用",
                          systemImage: model.voiceShortcutActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.voiceShortcutActive ? MapperColors.green :
                                         model.voiceShortcutRestorationPending ? MapperColors.amber : MapperColors.muted)
                }
                Text(model.voiceInputPreset.detail)
                    .foregroundStyle(MapperColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.voiceShortcutStatus)
                    .foregroundStyle((model.voiceShortcutEnabled && !model.voiceShortcutActive) ||
                                     model.voiceShortcutRestorationPending
                                     ? MapperColors.amber : MapperColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("这些预设发送 macOS 软件 Fn 事件，不伪装成实体 Globe 键。Typeless 已在本机实测；其他软件仍需以其当前版本和快捷键设置做首次验证。")
                    .foregroundStyle(MapperColors.muted)
            }
            .font(.system(size: 11))
            .padding(10)
            .background(MapperColors.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            if model.audioDriverReady && !model.audioRoutingEnabled {
                Text("系统能选到此麦克风，只表示组件已加载。还需在这里连接遥控器，并按住语音键才会有输入。")
                    .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.audioDriverReady {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Label(model.audioDriverStatus, systemImage: "exclamationmark.circle")
                            .foregroundStyle(MapperColors.amber)
                        Spacer(minLength: 8)
                        Button("安装说明", action: model.showInstallerHelp).buttonStyle(.borderless)
                        Button("重新检查", action: model.refreshAudioDriver).buttonStyle(.borderless)
                            .disabled(model.isReloadingAudioService)
                    }
                    Text(model.audioServiceReloadBlocked && !model.isReloadingAudioService
                         ? (model.canCheckAudioServiceRecovery
                            ? "上次重载结果待确认，请在上方重新检查后台状态。检查不会重载音频，也不会自动启用功能。"
                            : "为避免重复重载，本次请求不会再次发送；详情见上方状态。按键映射可独立使用。")
                         : model.audioDriverNeedsReload
                         ? "组件文件已安装。可使用上方“重新加载音频服务…”完成激活，无需为安装强制重启电脑。"
                         : "安装与激活状态独立检查。组件缺失或异常时，请使用同版本完整安装包修复；安装不要求重启电脑。")
                        .foregroundStyle(MapperColors.muted)
                }.font(.system(size: 11))
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Label(model.remoteMicrophoneIsSystemDefault
                          ? "系统默认输入：遥控器麦克风"
                          : "系统默认输入：\(model.systemDefaultInputName)",
                          systemImage: model.remoteMicrophoneIsSystemDefault ? "checkmark.circle.fill" : "mic.circle")
                        .foregroundStyle(model.remoteMicrophoneIsSystemDefault ? MapperColors.green : MapperColors.muted)
                    Spacer(minLength: 0)
                    if model.isChangingSystemDefaultInput { ProgressView().controlSize(.small) }
                    Button(model.systemDefaultInputActionTitle, action: model.toggleSystemDefaultInput)
                        .buttonStyle(.borderless).disabled(!model.canChangeSystemDefaultInput)
                        .help(model.remoteMicrophoneIsSystemDefault
                              ? "由你明确恢复本程序保存的原默认输入。"
                              : "只更改系统默认输入，不更改扬声器或系统音效。")
                    Button("声音设置", action: model.openSoundSettings).buttonStyle(.borderless)
                    Button("重新检查", action: model.refreshAudioDriver).buttonStyle(.borderless)
                        .disabled(model.isReloadingAudioService)
                }
                Text(model.systemDefaultInputStatus + " 有独立麦克风菜单的软件仍需选“遥控器麦克风”；助手无法读取其他软件内部当前选择。安装前已打开的软件可能需要完全退出后重开，并须获得麦克风权限。")
                    .foregroundStyle(MapperColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            if model.audioRoutingEnabled {
                HStack(spacing: 9) {
                    Text("音频电平").font(.system(size: 10)).foregroundStyle(MapperColors.muted)
                    ProgressView(value: min(max(model.voiceLevel, 0), 1))
                        .tint(MapperColors.green).frame(maxWidth: 220)
                }
            }
            DisclosureGroup("仅监听语音键快捷键", isExpanded: $keyDetailsExpanded) {
                HStack(spacing: 12) {
                    Text(model.audioRoutingEnabled
                         ? "语音键随麦克风连接；按键映射可一起使用。"
                         : "仅监听按键事件，不采集音频。")
                        .foregroundStyle(MapperColors.muted)
                    Spacer(minLength: 8)
                    Button(model.isVoiceEnabled ? "断开语音键" : "连接语音键", action: model.toggleVoice)
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(model.audioServiceActionsBlocked || model.audioRoutingEnabled || (!model.isDeviceBound && !model.isVoiceEnabled))
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11)).tint(MapperColors.muted)
        }
    }
}

private struct PermissionStatus: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? MapperColors.green : MapperColors.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(MapperColors.muted)
            }
            Spacer(minLength: 8)
            Text(granted ? "已授权" : "未授权")
                .foregroundStyle(granted ? MapperColors.green : MapperColors.amber)
            if !granted {
                Button("请求授权", action: request).buttonStyle(.link)
                Button("打开设置", action: openSettings).buttonStyle(.link)
            }
        }
        .font(.system(size: 11)).accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(granted ? "已授权" : "尚未授权")")
    }
}

private struct HIDServicePermissionStatus: View {
    @ObservedObject var model: MapperModel

    private var statusTitle: String {
        if model.hidServiceRootAccessDenied { return "管理员阶段被拒绝" }
        if model.hidServiceSessionVerified { return "本次已验证" }
        switch model.hidServiceInputPermission {
        case .checking: return "正在检查"
        case .granted: return "用户侧已允许"
        case .denied: return "未授权"
        case .unknown: return "尚未确认"
        }
    }

    private var statusColor: Color {
        if model.hidServiceRootAccessDenied { return MapperColors.amber }
        if model.hidServiceSessionVerified { return MapperColors.green }
        switch model.hidServiceInputPermission {
        case .granted: return MapperColors.accent
        case .denied: return MapperColors.amber
        case .checking: return MapperColors.accent
        case .unknown: return MapperColors.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if model.hidServiceInputPermission == .checking {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: model.hidServiceRootAccessDenied
                          ? "exclamationmark.circle"
                          : model.hidServiceSessionVerified
                          ? "checkmark.circle.fill"
                          : model.hidServiceInputPermission == .granted ? "checkmark.circle"
                          : model.hidServiceInputPermission == .denied ? "exclamationmark.circle" : "questionmark.circle")
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("按键服务输入监控").fontWeight(.medium)
                    Text("由 macOS 独立启动并核验，不借用主程序的授权结果。")
                        .foregroundStyle(MapperColors.muted)
                }
                Spacer(minLength: 8)
                Text(statusTitle).foregroundStyle(statusColor)
                if model.hidServiceRootAccessDenied || model.hidServiceInputPermission == .denied
                    || model.hidServiceInputPermission == .unknown {
                    Button("请求按键服务授权", action: model.requestHIDServiceInputAccess)
                        .buttonStyle(.link)
                        .disabled(!model.canRequestHIDServiceInputAccess)
                    Button("打开输入监控设置", action: model.openInputMonitoringSettings)
                        .buttonStyle(.link)
                        .disabled(model.isPreview)
                }
            }
            Text(model.hidServiceInputPermissionText)
                .foregroundStyle(model.hidServiceRootAccessDenied || model.hidServiceInputPermission == .denied
                                 ? MapperColors.amber : MapperColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("按键服务输入监控，\(statusTitle)。\(model.hidServiceInputPermissionText)")
    }
}

private struct RemotePhotoPanel: View {
    @ObservedObject var model: MapperModel
    @ObservedObject var store: PhotoLayoutStore
    @State private var showSchematic = false
    @State private var showWholePhoto = false
    private var showingWholePhoto: Bool { showWholePhoto || store.viewport == nil || store.isCalibrating }
    var body: some View {
        VStack(spacing: 10) {
            if let image = store.image, !showSchematic {
                CalibratedRemotePhoto(model: model, store: store, image: image,
                                      viewport: showingWholePhoto ? .full : (store.viewport ?? .full))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.isCalibrating {
                    Text("请点击照片上的“\(model.selectedButton.title)”键")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(MapperColors.accent)
                    Text("\(store.hotspots.count) / \(RemoteButton.allCases.count) 个位置已标记")
                        .font(.system(size: 10)).foregroundStyle(MapperColors.muted)
                } else {
                    Text("点击照片上的按键进行设置")
                        .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                }
                HStack(spacing: 12) {
                    Button(showingWholePhoto ? "聚焦按键" : "查看全图") {
                        if showingWholePhoto { store.focusOnHotspots(); showWholePhoto = false }
                        else { showWholePhoto = true }
                    }
                    .buttonStyle(.borderless).disabled(!store.isReady || store.isCalibrating)
                    if store.isReady {
                        Button(store.isCalibrating ? "取消调整" : "调整当前键") {
                            store.isCalibrating.toggle()
                            if store.isCalibrating { showWholePhoto = true }
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu("照片") {
                        Button("更换照片…", action: importPhoto)
                        Button("显示默认示意图") { showSchematic = true }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                .font(.system(size: 10))
            } else {
                RemoteIllustrationView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("RC003-MS 按键示意图 · 点击选键")
                    .font(.system(size: 11)).foregroundStyle(MapperColors.muted)
                HStack(spacing: 10) {
                    Button("导入自己的照片…", action: importPhoto).buttonStyle(.borderless)
                    if store.image != nil {
                        Button("查看已导入照片") { showSchematic = false }.buttonStyle(.borderless)
                    }
                }
                .font(.system(size: 10))
            }
            if !store.message.isEmpty {
                Text(store.message).font(.system(size: 10)).foregroundStyle(MapperColors.muted)
                    .lineLimit(2).multilineTextAlignment(.center).help(store.message)
            }
        }
        .padding(.vertical, 6)
        .help(store.sourceLabel)
    }

    private func importPhoto() {
        let panel = NSOpenPanel()
        panel.title = "导入遥控器正面照片"
        panel.message = "请选择正面清晰、尽量占满画面的照片。原图会保留，只另存一份用于按键位置。"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importPhoto(from: url)
        if store.image != nil { showSchematic = false; showWholePhoto = true }
        if store.isCalibrating, let button = store.nextUncalibratedButton { model.select(button) }
    }
}

/// A native, self-authored drawing. No bundled photograph, logo or third-party
/// artwork is used; the left key column and right volume rocker stay distinct.
private struct RemoteIllustrationView: View {
    @ObservedObject var model: MapperModel
    var body: some View {
        GeometryReader { geometry in
            let size = RemoteIllustrationLayout.size
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 39)
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.82), Color(white: 0.91)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 39).strokeBorder(Color(white: 0.72), lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 7, x: 1, y: 4)
                Circle().fill(Color(white: 0.87))
                    .overlay(Circle().strokeBorder(Color(white: 0.73), lineWidth: 1))
                    .frame(width: 118, height: 118).position(x: 90, y: 148)
                Capsule().fill(Color(white: 0.89))
                    .overlay(Capsule().strokeBorder(Color(white: 0.74), lineWidth: 1))
                    .frame(width: 47, height: 113).position(x: 130, y: 302)
                ForEach(RemoteIllustrationLayout.hotspots) { point in
                    if let button = point.remoteButton {
                        IllustratedRemoteButton(model: model, button: button)
                            .frame(width: point.width * size.width, height: point.height * size.height)
                            .position(x: point.x * size.width, y: point.y * size.height)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .padding(8)
    }
}

private struct IllustratedRemoteButton: View {
    @ObservedObject var model: MapperModel
    let button: RemoteButton
    @State private var hovered = false
    private var selected: Bool { model.selectedButton == button }
    private var pressed: Bool { model.lastPressedButtonID == button.id }
    private var separateFace: Bool {
        [.power, .microphone, .ok, .back, .home, .menu, .tv].contains(button)
    }
    var body: some View {
        Button { model.select(button) } label: {
            ZStack {
                Capsule()
                    .fill(pressed ? MapperColors.green.opacity(0.3) : selected ? MapperColors.accent.opacity(0.18)
                          : separateFace ? Color(white: 0.94) : hovered ? Color.white.opacity(0.45) : .clear)
                Capsule().strokeBorder(pressed ? MapperColors.green : selected ? MapperColors.accent
                    : separateFace ? Color(white: 0.76) : .clear, lineWidth: selected || pressed ? 2 : 1)
                if button == .tv {
                    Text("TV").font(.system(size: 13, weight: .semibold))
                } else if button == .ok {
                    Text("OK").font(.system(size: 12, weight: .semibold))
                } else {
                    Image(systemName: button.symbol).font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(button.canMap ? MapperColors.ink : MapperColors.muted)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help("\(button.title) → \(button.canMap ? model.bindingTitle(for: button) : "待验证，不映射")")
        .accessibilityLabel("示意图按键：\(button.title)，点击编辑")
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

private struct CalibratedRemotePhoto: View {
    @ObservedObject var model: MapperModel
    @ObservedObject var store: PhotoLayoutStore
    let image: NSImage
    let viewport: PhotoViewport
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / (image.size.width * viewport.width),
                            geometry.size.height / (image.size.height * viewport.height))
            let photoWidth = image.size.width * scale
            let photoHeight = image.size.height * scale
            let width = photoWidth * viewport.width
            let height = photoHeight * viewport.height
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: photoWidth, height: photoHeight)
                    .position(x: photoWidth * (0.5 - viewport.x), y: photoHeight * (0.5 - viewport.y))
                if store.isReady && !store.isCalibrating {
                    ForEach(store.hotspots) { hotspot in
                        if let button = hotspot.remoteButton {
                            PhotoHotspotButton(model: model, button: button)
                                .frame(width: photoWidth * hotspot.width, height: photoHeight * hotspot.height)
                                .position(x: photoWidth * (hotspot.x - viewport.x), y: photoHeight * (hotspot.y - viewport.y))
                        }
                    }
                }
                if store.isCalibrating {
                    ForEach(store.hotspots) { hotspot in
                        Circle().fill(MapperColors.accent).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                            .position(x: photoWidth * (hotspot.x - viewport.x), y: photoHeight * (hotspot.y - viewport.y))
                    }
                    Color.clear.contentShape(Rectangle())
                        .frame(width: width, height: height)
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard width > 0, height > 0 else { return }
                            let point = viewport.originalPoint(viewportX: value.location.x / width,
                                                               viewportY: value.location.y / height)
                            let saved = store.recordPoint(for: model.selectedButton,
                                x: point.x, y: point.y,
                                width: 32 / photoWidth, height: 32 / photoHeight)
                            if saved, store.isCalibrating, let next = store.nextUncalibratedButton { model.select(next) }
                        })
                        .position(x: width / 2, y: height / 2)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct PhotoHotspotButton: View {
    @ObservedObject var model: MapperModel
    let button: RemoteButton
    @State private var isHovered = false
    private var selected: Bool { model.selectedButton == button }
    private var pressed: Bool { model.lastPressedButtonID == button.id }
    var body: some View {
        Button { model.select(button) } label: {
            RoundedRectangle(cornerRadius: 7)
                .fill(pressed ? MapperColors.green.opacity(0.3) : selected ? MapperColors.accent.opacity(0.22) : isHovered ? MapperColors.accent.opacity(0.1) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(pressed ? MapperColors.green : selected || isHovered ? MapperColors.accent : .clear,
                                      lineWidth: selected || pressed ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { isHovered = $0 }
        .help("\(button.title) → \(button.canMap ? model.bindingTitle(for: button) : "待验证")")
        .accessibilityLabel("照片按键：\(button.title)，点击编辑")
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
