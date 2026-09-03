// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CoreAudio

protocol UninstallAudioMetadataReading {
    func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String
    func translate(_ text: String) throws -> AudioDeviceID
}

struct CoreAudioUninstallChecks: UninstallAudioChecking {
    private let ownUIDs = ["OpenRemoteAudio_UID", "OpenRemoteAudio_2_UID"]
    private let metadata: UninstallAudioMetadataReading
    init(metadata: UninstallAudioMetadataReading = CoreAudioUninstallMetadata()) { self.metadata = metadata }
    func checkSafe() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            let device = try metadata.number(system, selector)
            if device == kAudioObjectUnknown { continue }
            let uid = try metadata.string(device, kAudioDevicePropertyDeviceUID)
            guard !ownUIDs.contains(uid) else {
                throw UninstallFailure("请先在声音设置中选择其他默认输入、输出和音效设备；程序不会更改音频设置。")
            }
        }
        // The hidden output is intentionally absent from ordinary device lists.
        // Query both exact UIDs through TranslateUIDToDevice, not enumeration.
        for uid in ownUIDs {
            let device = try metadata.translate(uid)
            if device == kAudioObjectUnknown { continue }
            guard try metadata.string(device, kAudioDevicePropertyDeviceUID) == uid else {
                throw UninstallFailure("音频设备标识与查询结果不一致，拒绝卸载。")
            }
            guard try metadata.number(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else {
                throw UninstallFailure("遥控器麦克风输入或内部输出正在使用，请先结束录音、会议和接入程序。")
            }
        }
    }
}

/// Metadata queries only: no AudioUnit, AudioDeviceStart, default selection, or IO.
struct CoreAudioUninstallMetadata: UninstallAudioMetadataReading {
    func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { throw UninstallFailure("无法完整读取音频占用状态，拒绝卸载。") }
        return value
    }
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() as String?, !text.isEmpty else {
            throw UninstallFailure("无法读取音频设备身份，拒绝卸载。")
        }
        return text
    }
    func translate(_ text: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let string = text as CFString
        var qualifier = Unmanaged.passUnretained(string)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(string) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &size, &id)
        }
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size else {
            throw UninstallFailure("无法核查专用音频输入或隐藏输出，拒绝卸载。")
        }
        return id
    }
}

struct NativeUninstallProcessChecks: UninstallProcessChecking {
    func checkStopped() throws {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 200_000 else { throw UninstallFailure("无法查询运行进程，拒绝卸载。") }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 1024)
        let capacity = pids.count
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < capacity else { throw UninstallFailure("进程列表发生变化或无法完整读取，请重试。") }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            // PROC_PIDPATHINFO_MAXSIZE is a C arithmetic macro not imported by Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno = 0
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            if length > 0 {
                let executable = String(cString: path)
                if ["OpenRemoteAssistant", "OpenRemoteAudioServiceHelper", "OpenRemoteHIDCoreService", "OpenRemoteHIDSessionHelper"].contains(URL(fileURLWithPath: executable).lastPathComponent) {
                    throw UninstallFailure("主程序、按键辅助进程或音频重载工具仍在运行，请等待操作结束并退出主程序后再卸载；不会强制结束进程。")
                }
                continue
            }
            let pathError = errno
            var name = [CChar](repeating: 0, count: 1024)
            errno = 0
            let nameLength = proc_name(pid, &name, UInt32(name.count))
            if nameLength > 0 {
                let executableName = String(cString: name)
                if executableName.hasPrefix("OpenRemoteAssis") || executableName.hasPrefix("OpenRemoteAudio") || executableName.hasPrefix("OpenRemoteHID") {
                    throw UninstallFailure("主程序、按键辅助进程或音频重载工具可能仍在运行，请等待结束后重试；不会强制结束进程。")
                }
            } else if errno != ESRCH && pathError != ESRCH {
                throw UninstallFailure("无法核查某个运行进程，未假定主程序已经退出。")
            }
        }
    }
}

struct UninstallCommandResult { let status: Int32; let output: String }
protocol UninstallCommandRunning { func run(arguments: [String]) throws -> UninstallCommandResult }

/// Only this executable and the exact approved receipt argument forms can run.
struct PkgutilCommandRunner: UninstallCommandRunning {
    func run(arguments: [String]) throws -> UninstallCommandResult {
        let permitted = [["--pkgs"]] + UninstallCoordinator.receiptIDs.map { ["--forget", $0] }
        guard permitted.contains(arguments) else { throw UninstallFailure("拒绝非白名单收据命令。") }
        var info = stat()
        guard lstat("/usr/sbin/pkgutil", &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0 else {
            throw UninstallFailure("系统 pkgutil 身份或权限异常。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard output.count <= 1_048_576 else { throw UninstallFailure("系统收据命令返回异常长度输出。") }
        return UninstallCommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}

struct PkgutilUninstallReceipts: UninstallReceiptManaging {
    let runner: UninstallCommandRunning
    init(runner: UninstallCommandRunning = PkgutilCommandRunner()) { self.runner = runner }
    func installed() throws -> Set<String> {
        // Filter locally because --pkgs=REGEXP returns exit 1 for no match on
        // macOS. Never interpret a failed query as "not installed". Other
        // products' IDs are not logged, returned, retained, or acted upon.
        let response = try runner.run(arguments: ["--pkgs"])
        guard response.status == 0, response.output.utf8.count <= 1_048_576 else {
            throw UninstallFailure("查询本产品收据失败（\(response.status)）或输出过大；未忽略错误。")
        }
        let matching = response.output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { UninstallCoordinator.receiptIDs.contains($0) }
        guard Set(matching).count == matching.count else { throw UninstallFailure("本产品收据查询返回重复标识。") }
        return Set(matching)
    }
    func forget(_ identifier: String) throws {
        guard UninstallCoordinator.receiptIDs.contains(identifier) else { throw UninstallFailure("拒绝移除其他产品收据。") }
        let response = try runner.run(arguments: ["--forget", identifier])
        guard response.status == 0 else { throw UninstallFailure("删除收据 \(identifier) 失败（\(response.status)）；文件可能已移除，请保留结果并重试。") }
    }
}
