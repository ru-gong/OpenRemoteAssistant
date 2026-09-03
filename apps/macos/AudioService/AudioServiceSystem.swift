// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import Security
import CoreAudio

struct AudioServiceBundle {
    let components: [String]
    let identifier: String
    let executable: String
    let packageType: String
    let version: String
    let build: String
    var path: String { "/" + components.joined(separator: "/") }
    static let driver = AudioServiceBundle(components: ["Library", "Audio", "Plug-Ins", "HAL", "OpenRemoteAudio.driver"],
        identifier: "org.rc001remote.audio", executable: "OpenRemoteAudio", packageType: "BNDL", version: "0.1.1", build: "2")
    static let application = AudioServiceBundle(components: ["Applications", "遥控器助手.app"],
        identifier: "org.rc001remote.assistant", executable: "OpenRemoteAssistant", packageType: "APPL", version: "0.2.7", build: "14")
}

protocol AudioServiceSignatureChecking { func checkBundle(at path: String) throws }
struct AudioServiceSignature: AudioServiceSignatureChecking {
    func checkBundle(at path: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { throw AudioServiceFailure("无法读取安装组件的代码签名：\(path)") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw AudioServiceFailure("安装组件签名或内容损坏，请重新安装匹配版本：\(path)")
        }
    }
}

private final class AudioServiceFD {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}

/// Read-only fixed-installation validation. Fixture injection is internal;
/// production CLI has no root path, target, or expected-version argument.
struct AudioServiceInstallation: AudioServiceInstallationChecking {
    let rootPath: String
    let owner: uid_t
    let applicationsGroup: gid_t
    let signature: AudioServiceSignatureChecking
    static func production() -> AudioServiceInstallation {
        AudioServiceInstallation(rootPath: "/", owner: 0, applicationsGroup: 80, signature: AudioServiceSignature())
    }

    func checkInstalled() throws {
        let root = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure("无法安全打开安装检查根目录") }
        let heldRoot = AudioServiceFD(root)
        try validatePermissions(root, info: info(root), applicationsParent: false)
        for bundle in [AudioServiceBundle.driver, .application] {
            var parent = heldRoot
            for (index, component) in bundle.components.dropLast().enumerated() {
                parent = try openNode(parent.value, name: component, directory: true)
                try validatePermissions(parent.value, info: info(parent.value),
                    applicationsParent: bundle.path == AudioServiceBundle.application.path && index == 0)
                if component == "HAL", try names(parent.value).contains(where: { $0.hasPrefix(".OpenRemoteUninstall-") }) {
                    throw AudioServiceFailure("发现尚未处理的卸载隔离目录，请先完成卸载恢复，不发送重载请求。")
                }
            }
            let leaf = bundle.components.last!
            let directory = try openNode(parent.value, name: leaf, directory: true)
            let identity = try info(directory.value)
            var count = 0
            try validateTree(directory.value, device: identity.st_dev, depth: 0, count: &count)
            try validatePlistAndExecutable(directory.value, bundle: bundle)
            let path = rootPath == "/" ? bundle.path : rootPath + bundle.path
            try signature.checkBundle(at: path)
            // /Applications is normally root:admin 0775. An administrator may
            // rename its leaf, but may not cause a substituted tree to pass.
            let after = try entry(parent.value, name: leaf)
            guard sameIdentity(identity, after) else { throw AudioServiceFailure("安装组件在检查期间被替换，拒绝重载。") }
            var secondCount = 0
            try validateTree(directory.value, device: identity.st_dev, depth: 0, count: &secondCount)
            try validatePlistAndExecutable(directory.value, bundle: bundle)
        }
    }

    /// Shared with the read-only QA probe. This does not inspect the installed
    /// product version, enumerate audio, or send any process signal.
    func checkCoreAudioSystemAssets(appleSignature: AudioServiceSignatureChecking = AudioServiceAppleSignature()) throws {
        let root = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure("无法打开系统资产检查根目录") }
        let heldRoot = AudioServiceFD(root)
        try validatePermissions(root, info: info(root), applicationsParent: false)
        let paths = [["System", "Library", "LaunchDaemons", "com.apple.audio.coreaudiod.plist"], ["usr", "sbin", "coreaudiod"]]
        for (index, components) in paths.enumerated() {
            var parent = heldRoot
            for component in components.dropLast() {
                parent = try openNode(parent.value, name: component, directory: true)
                try validatePermissions(parent.value, info: info(parent.value), applicationsParent: false)
            }
            let leaf = components.last!
            let file = try openNode(parent.value, name: leaf, directory: false)
            let before = try info(file.value)
            try validatePermissions(file.value, info: before, applicationsParent: false)
            guard before.st_size > 0 else { throw AudioServiceFailure("系统音频资产为空。") }
            if index == 0 {
                guard before.st_size <= 1_048_576 else { throw AudioServiceFailure("系统音频服务描述长度异常。") }
                var data = Data(count: Int(before.st_size))
                let bytes = data.withUnsafeMutableBytes { pread(file.value, $0.baseAddress, $0.count, 0) }
                guard bytes == data.count,
                      let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      plist["Label"] as? String == "com.apple.audio.coreaudiod",
                      plist["UserName"] as? String == "_coreaudiod", plist["GroupName"] as? String == "_coreaudiod",
                      plist["ProgramArguments"] as? [String] == ["/usr/sbin/coreaudiod"],
                      plist["Program"] == nil || plist["Program"] as? String == "/usr/sbin/coreaudiod",
                      plist["Disabled"] as? Bool != true else {
                    throw AudioServiceFailure("系统音频服务描述与固定目标不一致，拒绝请求。")
                }
            } else {
                guard before.st_mode & 0o100 != 0 else { throw AudioServiceFailure("系统音频可执行文件权限异常。") }
                let path = (rootPath == "/" ? "" : rootPath) + "/usr/sbin/coreaudiod"
                try appleSignature.checkBundle(at: path)
            }
            let after = try entry(parent.value, name: leaf)
            guard sameIdentity(before, after), before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                throw AudioServiceFailure("系统音频资产在核验期间发生变化。")
            }
        }
    }

    private func validatePlistAndExecutable(_ root: Int32, bundle: AudioServiceBundle) throws {
        let contents = try openNode(root, name: "Contents", directory: true)
        let plist = try openNode(contents.value, name: "Info.plist", directory: false)
        let metadata = try info(plist.value)
        guard metadata.st_size > 0, metadata.st_size <= 1_048_576 else { throw AudioServiceFailure("安装组件 Info.plist 长度异常。") }
        var data = Data(count: Int(metadata.st_size))
        let readCount = data.withUnsafeMutableBytes { pread(plist.value, $0.baseAddress, $0.count, 0) }
        guard readCount == data.count,
              let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AudioServiceFailure("无法读取安装组件的身份。")
        }
        let expected = ["CFBundleIdentifier": bundle.identifier, "CFBundleExecutable": bundle.executable,
            "CFBundlePackageType": bundle.packageType, "CFBundleShortVersionString": bundle.version, "CFBundleVersion": bundle.build]
        guard expected.allSatisfy({ values[$0.key] as? String == $0.value }) else {
            throw AudioServiceFailure("安装组件身份或版本不匹配：需要 \(bundle.version)（\(bundle.build)）的 \(bundle.path)。请先完成匹配版本安装。")
        }
        let macOS = try openNode(contents.value, name: "MacOS", directory: true)
        let executable = try openNode(macOS.value, name: bundle.executable, directory: false)
        let executableInfo = try info(executable.value)
        guard executableInfo.st_size > 0, executableInfo.st_mode & 0o100 != 0 else { throw AudioServiceFailure("安装组件缺少有效可执行文件。") }
    }

    private func validateTree(_ fd: Int32, device: dev_t, depth: Int, count: inout Int) throws {
        count += 1
        let current = try info(fd)
        guard depth <= 32, count <= 20_000, current.st_dev == device else { throw AudioServiceFailure("安装组件目录异常、过深或跨文件系统。") }
        try validatePermissions(fd, info: current, applicationsParent: false)
        if current.st_mode & S_IFMT == S_IFDIR {
            for name in try names(fd) {
                let metadata = try entry(fd, name: name)
                let child = try openNode(fd, name: name, directory: metadata.st_mode & S_IFMT == S_IFDIR)
                try validateTree(child.value, device: device, depth: depth + 1, count: &count)
            }
        }
    }
    private func validatePermissions(_ fd: Int32, info: stat, applicationsParent: Bool) throws {
        let kind = info.st_mode & S_IFMT
        guard (kind == S_IFREG || kind == S_IFDIR), info.st_uid == owner,
              info.st_mode & 0o7002 == 0,
              info.st_mode & 0o020 == 0 || (applicationsParent && info.st_gid == applicationsGroup),
              kind != S_IFREG || info.st_nlink == 1 else {
            throw AudioServiceFailure("安装路径含链接、特殊文件、非预期所有权或可写权限，拒绝重载。")
        }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { _ = try self.info(fd); return }
            throw failure("无法读取安装路径 ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw failure("安装路径 ACL 异常") }
        var item: acl_entry_t?
        var kindOfEntry = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let status = acl_get_entry(acl, Int32(kindOfEntry.rawValue), &item)
            if status == -1 && errno == EINVAL { break }
            guard status == 0, let item else { throw failure("读取安装路径 ACL 失败") }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(item, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw AudioServiceFailure("安装路径存在扩展允许权限，拒绝提权重载。")
            }
            kindOfEntry = ACL_NEXT_ENTRY
        }
    }
    private func info(_ fd: Int32) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0 else { throw failure("无法读取打开的安装条目") }
        return result
    }
    private func entry(_ parent: Int32, name: String) throws -> stat {
        var result = stat()
        guard fstatat(parent, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("缺少或无法读取安装条目 \(name)") }
        return result
    }
    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
    }
    private func openNode(_ parent: Int32, name: String, directory: Bool) throws -> AudioServiceFD {
        let before = try entry(parent, name: name)
        guard before.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw AudioServiceFailure("安装路径类型异常或包含符号链接：\(name)") }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw failure("无法安全打开安装条目 \(name)") }
        let held = AudioServiceFD(fd)
        guard sameIdentity(before, try info(fd)) else { throw AudioServiceFailure("安装条目在打开期间发生变化。") }
        return held
    }
    private func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw failure("无法复制安装目录描述符") }
        guard let directory = fdopendir(copy) else { close(copy); throw failure("无法枚举安装目录") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                guard errno == 0 else { throw failure("读取安装目录失败") }
                return result.sorted()
            }
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name, !name.isEmpty, !name.contains("/") else { throw AudioServiceFailure("安装目录含异常名称。") }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= 20_000 else { throw AudioServiceFailure("安装目录条目过多。") }
        }
    }
    private func failure(_ message: String) -> AudioServiceFailure { AudioServiceFailure(message + "（errno \(errno)）。") }
}

struct AudioServiceProcess {
    let pid: pid_t
    let name: String
    let fullPathAvailable: Bool
}
protocol AudioServiceProcessReading { func snapshot() throws -> [AudioServiceProcess] }
struct AudioServiceProcesses: AudioServiceProcessChecking {
    let reader: AudioServiceProcessReading
    let ownPID: pid_t
    init(reader: AudioServiceProcessReading = AudioServiceProcessReader(), ownPID: pid_t = getpid()) {
        self.reader = reader; self.ownPID = ownPID
    }
    func checkNoConflict() throws {
        let forbidden: Set<String> = ["Installer", "installer", "OpenRemoteUninstaller", "OpenRemoteUninstallHelper", "OpenRemoteAudioServiceHelper"]
        for process in try reader.snapshot() where process.pid != ownPID {
            if forbidden.contains(process.name) || (!process.fullPathAvailable &&
                (process.name.hasPrefix("OpenRemoteUninst") || process.name.hasPrefix("OpenRemoteAudio"))) {
                throw AudioServiceFailure("安装器、卸载工具或另一个音频重载助手仍在运行。即使安装器只是打开，也请先退出其窗口并等待相关操作结束后重试；不会强制关闭它们。")
            }
        }
    }
}
struct AudioServiceProcessReader: AudioServiceProcessReading {
    func snapshot() throws -> [AudioServiceProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 200_000 else { throw AudioServiceFailure("无法查询安装与卸载并发状态。") }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 1024)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { throw AudioServiceFailure("无法完整读取并发进程，请稍后重试。") }
        var result: [AudioServiceProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno = 0
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                result.append(AudioServiceProcess(pid: pid, name: URL(fileURLWithPath: String(cString: path)).lastPathComponent, fullPathAvailable: true))
                continue
            }
            let pathError = errno
            var name = [CChar](repeating: 0, count: 1024)
            errno = 0
            if proc_name(pid, &name, UInt32(name.count)) > 0 {
                result.append(AudioServiceProcess(pid: pid, name: String(cString: name), fullPathAvailable: false))
            } else if errno != ESRCH && pathError != ESRCH {
                throw AudioServiceFailure("无法核查某个并发进程，未假定安装或卸载已结束。")
            }
        }
        return result
    }
}

protocol AudioServiceEndpointReading {
    func catalogCompatibility() -> VoiceAudioCatalogCompatibility?
    func isRegistered(_ uid: String) throws -> Bool
}
struct AudioServiceEndpointProbe: AudioServiceReadinessChecking {
    let reader: AudioServiceEndpointReading
    init(reader: AudioServiceEndpointReading = AudioServiceEndpointReader()) { self.reader = reader }
    func state() throws -> AudioServiceReadiness {
        switch reader.catalogCompatibility() {
        case .current?: return .ready
        case .previousVirtualInput?: return .reloadRequired
        case .invalid?:
            throw AudioServiceFailure("专用音频端点已注册，但身份、通道、在线状态或版本组合不符合要求；未发送重载请求。")
        case nil: break
        }
        let input = try reader.isRegistered(VoiceAudioCatalog.inputUID)
        let output = try reader.isRegistered(VoiceAudioCatalog.outputUID)
        guard !input && !output else {
            throw AudioServiceFailure("发现部分专用音频端点或身份/通道/在线状态不完整，不能将其当成尚未加载；请重新检查或修复安装。")
        }
        return .reloadRequired
    }
}
/// Read-only metadata only. VoiceAudioCatalog supplies the same complete
/// dual-endpoint identity/alive/channel policy used by the main app. No output
/// object, queue, microphone, stream, or cached AudioObjectID is created here.
struct AudioServiceEndpointReader: AudioServiceEndpointReading {
    func catalogCompatibility() -> VoiceAudioCatalogCompatibility? {
        VoiceAudioCatalog.snapshot()?.compatibility
    }
    func isRegistered(_ uid: String) throws -> Bool {
        guard [VoiceAudioCatalog.inputUID, VoiceAudioCatalog.outputUID].contains(uid) else {
            throw AudioServiceFailure("拒绝查询非本产品音频端点。")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let value = uid as CFString
        var qualifier = Unmanaged.passUnretained(value)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(value) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size), &qualifier, &size, &id)
        }
        guard status == noErr, size == MemoryLayout<AudioDeviceID>.size else {
            throw AudioServiceFailure("无法可靠查询专用音频端点，未将查询错误当成尚未加载。")
        }
        // The documented missing-UID outcome is noErr + kAudioObjectUnknown.
        return id != kAudioObjectUnknown
    }
}
