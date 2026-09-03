import SwiftUI
import AppKit
import Darwin

final class MapperAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: MapperModel?
    private var signals: [DispatchSourceSignal] = []
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        guard model.confirmExitDuringAudioServiceReload() else { return .terminateCancel }
        terminationPending = true
        model.prepareToQuit { [weak self] shouldQuit in
            DispatchQueue.main.async {
                if !shouldQuit { self?.terminationPending = false }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MapperApplication: App {
    @NSApplicationDelegateAdaptor(MapperAppDelegate.self) private var delegate
    @StateObject private var model = MapperModel()
    var body: some Scene {
        WindowGroup("遥控器助手", id: "settings") {
            MapperView(model: model)
                .onAppear { MapperAppDelegate.model = model }
        }
        .defaultSize(width: 970, height: 830)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("遥控器") {
                Button("停止映射") { model.stopMapping() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("停止全部") { model.stopAll() }
                Divider()
                Button("导入已有映射…") { model.importMappings() }
                    .disabled(model.audioServiceActionsBlocked)
                Button("显示配置文件") { model.showConfiguration() }
                Divider()
                Button("安装说明…") { model.showInstallerHelp() }
                Button("开源许可（GPLv3）…") { model.showOpenSourceLicense() }
                if model.audioDriverNeedsReload {
                    Button("重新加载音频服务…") { model.requestAudioServiceReload() }
                        .disabled(model.audioServiceReloadBlocked)
                }
                if model.canCheckAudioServiceRecovery {
                    Button("重新检查并恢复操作") { model.refreshAudioDriver() }
                }
                Button("卸载遥控器助手…") { model.showUninstaller() }
                    .disabled(model.audioServiceActionsBlocked)
            }
        }
        MenuBarExtra("遥控器助手", systemImage: "appletvremote.gen1") {
            MapperMenu(model: model)
        }
    }
}

private struct MapperMenu: View {
    @ObservedObject var model: MapperModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.isDeviceBound ? "设备已绑定" : "尚未绑定遥控器")
        Text(model.isMappingStarting ? "按键映射：等待启用" : model.isMappingStopping ? "按键映射：正在停止" : model.isMappingEnabled ? "按键映射：已启用" : "按键映射：未启用")
        Text(model.audioRoutingEnabled ? "麦克风：接入已启动" : "麦克风：未接入")
        if model.audioRoutingEnabled || model.isVoiceEnabled { Text(model.voiceStatusText) }
        Divider()
        Button("打开遥控器助手") {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(model.isMappingStopping ? "检查停止状态" : model.isMappingStarting ? "取消启用" : "停止映射") {
            if model.isMappingStarting || model.isMappingStopping { model.toggleMapping() } else { model.stopMapping() }
        }.disabled(!model.isMappingEnabled && !model.isMappingStarting && !model.isMappingStopping)
        Button("停止全部") { model.stopAll() }
            .disabled(!model.isMappingEnabled && !model.isMappingStarting && !model.isMappingStopping && !model.isVoiceEnabled && !model.audioRoutingEnabled && !model.isRecording && !model.isSearchingDevices)
        Divider()
        Button("安装说明…") { model.showInstallerHelp() }
        Button("开源许可（GPLv3）…") { model.showOpenSourceLicense() }
        if model.audioDriverNeedsReload {
            Button("重新加载音频服务…") { model.requestAudioServiceReload() }
                .disabled(model.audioServiceReloadBlocked)
        }
        if model.canCheckAudioServiceRecovery {
            Button("重新检查并恢复操作") { model.refreshAudioDriver() }
        }
        Button("卸载遥控器助手…") { model.showUninstaller() }
            .disabled(model.audioServiceActionsBlocked)
        Divider()
        Button("退出遥控器助手") { NSApplication.shared.terminate(nil) }
    }
}
