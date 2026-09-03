// SPDX-License-Identifier: GPL-3.0-only
// Read-only CoreAudio metadata helper. No IOProc, capture or device mutation.
import Foundation
import CoreAudio
import Darwin

func checkProductProcessesStopped() {
    let executableNames: Set<String> = ["OpenRemoteAssistant", "OpenRemoteUninstaller", "OpenRemoteUninstallHelper", "OpenRemoteAudioServiceHelper", "OpenRemoteHIDCoreService", "OpenRemoteHIDSessionHelper"]
    func refuse(_ text: String) -> Never { fputs(text + "\n", stderr); exit(5) }
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0, estimate < 200_000 else { refuse("无法查询运行进程，未执行安装。") }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 1024)
    let capacity = pids.count
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0, count < capacity else { refuse("无法完整查询运行进程，请稍后重试。") }
    for pid in pids.prefix(Int(count)) where pid > 0 {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN in the current Darwin SDK;
        // its arithmetic C macro is not imported as a Swift symbol.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        if length > 0 {
            if executableNames.contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent) {
                refuse("遥控器助手、按键辅助进程、卸载或音频重载工具仍在运行。请等待操作结束并退出相关窗口后再安装；不会强退程序。")
            }
            continue
        }
        let pathError = errno
        var name = [CChar](repeating: 0, count: 1024)
        errno = 0
        let nameLength = proc_name(pid, &name, UInt32(name.count))
        if nameLength > 0 {
            let value = String(cString: name)
            // An inaccessible full path with a possibly truncated product name
            // is ambiguous and fails closed rather than allowing an upgrade.
            if executableNames.contains(value) || value.hasPrefix("OpenRemoteAssis") || value.hasPrefix("OpenRemoteUninst") || value.hasPrefix("OpenRemoteAudio") || value.hasPrefix("OpenRemoteHID") {
                refuse("可能仍有本产品进程运行，请退出后重试。")
            }
        } else if errno != ESRCH && pathError != ESRCH {
            refuse("无法核查某个运行进程，未执行安装。")
        }
    }
}

func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var result: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : nil
}
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return nil }
    return result?.takeRetainedValue() as String?
}
func translate(_ uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let value = uid as CFString
    var qualifier = Unmanaged.passUnretained(value)
    var result = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withExtendedLifetime(value) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &size, &result)
    }
    return status == noErr ? result : nil
}
let system = AudioObjectID(kAudioObjectSystemObject)
let uninstall = CommandLine.arguments.contains("--uninstall-check")
let install = CommandLine.arguments.contains("--install-check")
let requestedOperation = uninstall ? "卸载" : install ? "安装" : "查询"
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
      size > 0, size <= 65536 else { fputs("无法检查音频状态，未执行\(requestedOperation)。\n", stderr); exit(2) }
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { exit(2) }
let inputID = number(system, kAudioHardwarePropertyDefaultInputDevice)
let outputID = number(system, kAudioHardwarePropertyDefaultOutputDevice)
let effectsID = number(system, kAudioHardwarePropertyDefaultSystemOutputDevice)
if uninstall || install {
    if !uninstall { checkProductProcessesStopped() }
    guard let inputID, let outputID, let effectsID else { exit(2) }
    let ownUIDs = ["OpenRemoteAudio_UID", "OpenRemoteAudio_2_UID"]
    for id in [inputID, outputID, effectsID] where id != kAudioObjectUnknown {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { exit(2) }
        if uninstall && ownUIDs.contains(uid) {
            fputs("请先在声音设置中选择其他默认设备，再重新运行卸载。未更改任何音频设置。\n", stderr); exit(3)
        }
    }
    // Hidden outputs are not necessarily in kAudioHardwarePropertyDevices.
    for uid in ownUIDs {
        guard let id = translate(uid) else { exit(2) }
        if id == kAudioObjectUnknown { continue }
        guard string(id, kAudioDevicePropertyDeviceUID) == uid else { exit(2) }
        guard let running = number(id, kAudioDevicePropertyDeviceIsRunningSomewhere) else { exit(2) }
        if running != 0 { fputs("遥控器麦克风正在使用，请先退出本程序并结束相关录音/会议，再运行安装或卸载。\n", stderr); exit(4) }
    }
    print("音频状态允许继续安装/卸载；未更改任何设备。")
} else {
    let rows: [[String: Any]] = ids.map { id in
        ["uid": string(id, kAudioDevicePropertyDeviceUID) ?? "", "name": string(id, kAudioObjectPropertyName) ?? "",
         "defaultInput": id == inputID, "defaultOutput": id == outputID, "systemOutput": id == effectsID]
    }
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
