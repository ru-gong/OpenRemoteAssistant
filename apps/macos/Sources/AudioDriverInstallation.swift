// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import Security
import CoreAudio

enum AudioEndpointPresence: Equatable { case absent, present, queryFailed }

enum AudioDriverDiskState: Equatable {
    case missing
    case invalid(String)
    case installed
}

enum AudioDriverAvailability: Equatable {
    case missing
    case invalid(String)
    case installedUnloaded
    case installedStale
    case unavailable(String)
    case ready

    var needsReload: Bool { self == .installedUnloaded || self == .installedStale }
    var isReady: Bool { self == .ready }
    var message: String {
        switch self {
        case .missing: return "尚未安装专用麦克风组件。请运行完整安装包；重新加载音频服务不能补装驱动。"
        case .invalid(let reason): return "音频组件路径或身份异常。请先按安装器的具体报错处理冲突目标；不会覆盖身份不明的文件。" + reason
        case .installedUnloaded: return "音频组件已安装，尚未生效。可以在结束会议后重新加载音频服务。"
        case .installedStale: return "新版音频组件已安装，但系统仍在使用旧端点。可以在结束会议后重新加载音频服务。"
        case .unavailable(let reason): return "暂时无法确认音频组件状态。" + reason
        case .ready: return "音频组件已生效。目标软件的输入设备选“遥控器麦克风”；这不代表已验证遥控器收音。"
        }
    }
}

/// This is an installation diagnostic, not an authorization boundary. The
/// privileged helper independently checks the entire fixed bundle tree before
/// submitting a service request. This reader never installs or changes files.
enum AudioDriverInstallation {
    static let driverURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver", isDirectory: true)

    static func inspect() -> AudioDriverDiskState {
        inspect(at: driverURL, expectedOwner: 0, signatureCheck: signatureIsValid)
    }

    static func read() -> (availability: AudioDriverAvailability, devices: [VoiceAudioDevice]) {
        let disk = inspect()
        guard disk == .installed else {
            return (classify(disk: disk, catalogReady: false, input: .queryFailed, output: .queryFailed), [])
        }
        if let snapshot = VoiceAudioCatalog.snapshot() {
            switch snapshot.compatibility {
            case .current:
                return (.ready, [VoiceAudioDevice(uid: VoiceAudioCatalog.outputUID,
                    name: VoiceAudioCatalog.inputName, deviceID: snapshot.output)])
            case .previousVirtualInput:
                return (classify(disk: disk, catalogReady: false, input: .present, output: .present,
                    knownPreviousLoaded: true), [])
            case .invalid: break
            }
        }
        return (classify(disk: disk, catalogReady: false,
            input: presence(of: VoiceAudioCatalog.inputUID), output: presence(of: VoiceAudioCatalog.outputUID)), [])
    }

    static func classify(disk: AudioDriverDiskState, catalogReady: Bool,
                         input: AudioEndpointPresence, output: AudioEndpointPresence,
                         knownPreviousLoaded: Bool = false) -> AudioDriverAvailability {
        switch disk {
        case .missing: return .missing
        case .invalid(let message): return .invalid(message)
        case .installed:
            if catalogReady { return .ready }
            if knownPreviousLoaded { return .installedStale }
            if input == .queryFailed || output == .queryFailed {
                return .unavailable("系统音频查询未成功，请稍后重新检查；不会据此请求重载。")
            }
            if input == .absent && output == .absent { return .installedUnloaded }
            return .unavailable("发现部分专用端点，但身份、通道或在线状态未通过完整校验。请重新检查，若持续请修复安装。")
        }
    }

    private static func presence(of uid: String) -> AudioEndpointPresence {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let string = uid as CFString
        var qualifier = Unmanaged.passUnretained(string)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var count = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(string) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &count, &device)
        }
        // CoreAudio's documented missing-UID result is noErr plus Unknown.
        guard status == noErr, count == MemoryLayout<AudioDeviceID>.size else { return .queryFailed }
        return device == kAudioObjectUnknown ? .absent : .present
    }

    /// Only tests supply another root/owner/signature checker; no runtime CLI or
    /// UI accepts a driver path or relaxes production validation.
    static func inspect(at root: URL, expectedOwner: uid_t,
                        signatureCheck: (URL) -> Bool) -> AudioDriverDiskState {
        var top = stat()
        if lstat(root.path, &top) != 0 {
            return errno == ENOENT ? .missing : .invalid("无法读取组件目录，请检查完整安装。")
        }
        let entries: [(String, Bool)] = [("", true), ("Contents", true), ("Contents/MacOS", true),
            ("Contents/Info.plist", false), ("Contents/MacOS/OpenRemoteAudio", false)]
        for (path, directory) in entries {
            let url = path.isEmpty ? root : root.appendingPathComponent(path)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  metadata.st_uid == expectedOwner,
                  metadata.st_mode & 0o022 == 0 else {
                return .invalid("组件文件缺失、类型不符或权限异常；不会尝试重新加载。")
            }
            if path == "Contents/MacOS/OpenRemoteAudio", metadata.st_mode & 0o100 == 0 {
                return .invalid("音频驱动文件不可执行。")
            }
        }
        let plistURL = root.appendingPathComponent("Contents/Info.plist")
        guard let values = try? plistURL.resourceValues(forKeys: [.fileSizeKey]),
              let count = values.fileSize, count > 0, count < 128_000,
              let data = try? Data(contentsOf: plistURL), data.count < 128_000,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "org.rc001remote.audio",
              plist["CFBundleExecutable"] as? String == "OpenRemoteAudio",
              plist["CFBundlePackageType"] as? String == "BNDL",
              plist["CFBundleShortVersionString"] as? String == "0.1.1",
              plist["CFBundleVersion"] as? String == "2" else {
            return .invalid("组件身份或版本不符合此版本要求。")
        }
        guard signatureCheck(root) else { return .invalid("组件签名或文件完整性校验失败。") }
        return .installed
    }

    private static func signatureIsValid(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess
    }

    static func previewState(arguments: [String], plistValue: String?) -> AudioDriverAvailability {
        let option = "--audio-driver-preview-state"
        let value: String?
        if let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) {
            value = arguments[index + 1]
        } else { value = plistValue }
        switch value {
        case "installed-unloaded": return .installedUnloaded
        case "installed-stale": return .installedStale
        case "ready": return .ready
        default: return .missing
        }
    }
}
