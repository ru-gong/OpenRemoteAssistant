// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import Security
import IOKit.hid
import CryptoKit

struct HIDSessionClientIdentity: Equatable {
    let pid: Int32
    let uid: UInt32
    let realUID: UInt32
    let savedUID: UInt32
    let startSeconds: Int
    let startMicroseconds: Int32
    let path: String
}

/// One authenticated snapshot of the process on the other end of the
/// permission socket. The audit token includes pidversion, so an exec or PID
/// reuse cannot be mistaken for the process execution that was first checked.
struct HIDPermissionClientIdentity: Equatable {
    let process: HIDSessionClientIdentity
    let auditToken: Data
    let pidVersion: Int32
}

/// IORegistry queries do not create an IOHIDDevice or its input user client.
/// Keep the selected service retained until the caller finishes its operation.
enum HIDSessionRegistry {
    struct Snapshot: Codable {
        let registryID: UInt64
        let locationID: Int
        let vendorID: Int
        let productID: Int
        let transport: String
        let usagePage: Int
        let usage: Int
    }

    static func withUniqueService<T>(registryID: UInt64, locationID: Int,
                                    _ operation: (io_service_t, Snapshot) throws -> T) throws -> T {
        let matching: [String: Any] = [
            kIOProviderClassKey: "IOHIDDevice",
            kIOPropertyMatchKey: [kIOHIDVendorIDKey: HIDSessionRules.vendorID,
                                  kIOHIDProductIDKey: HIDSessionRules.productID]
        ]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == kIOReturnSuccess else {
            throw HIDSessionFailure("device_metadata", "无法完整查询遥控器设备元数据；未选择其他键盘。")
        }
        defer { IOObjectRelease(iterator) }
        var retained: [io_service_t] = []
        defer { retained.forEach { IOObjectRelease($0) } }
        var candidates: [(io_service_t, Snapshot)] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            retained.append(service)
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let values = properties?.takeRetainedValue() as? [String: Any],
                  let vendor = values[kIOHIDVendorIDKey] as? NSNumber,
                  let product = values[kIOHIDProductIDKey] as? NSNumber,
                  vendor.intValue == HIDSessionRules.vendorID, product.intValue == HIDSessionRules.productID,
                  let transport = values[kIOHIDTransportKey] as? String,
                  let page = values[kIOHIDPrimaryUsagePageKey] as? NSNumber,
                  let usage = values[kIOHIDPrimaryUsageKey] as? NSNumber else {
                throw HIDSessionFailure("device_metadata", "遥控器设备元数据不完整；无法安全确认唯一设备。")
            }
            guard transport == "Bluetooth Low Energy", page.intValue == 1, usage.intValue == 6 else { continue }
            var identifier: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &identifier) == kIOReturnSuccess, identifier > 0,
                  let location = values[kIOHIDLocationIDKey] as? NSNumber,
                  location.int64Value >= 0, location.int64Value <= Int64(UInt32.max) else {
                throw HIDSessionFailure("device_metadata", "无法核实遥控器的本机设备标识。")
            }
            candidates.append((service, Snapshot(registryID: identifier, locationID: location.intValue,
                vendorID: vendor.intValue, productID: product.intValue, transport: transport,
                usagePage: page.intValue, usage: usage.intValue)))
        }
        guard IOIteratorIsValid(iterator) != 0 else {
            throw HIDSessionFailure("device_changed", "设备列表在查询期间发生变化；请重新确认连接。")
        }
        guard candidates.count == 1, let (service, snapshot) = candidates.first else {
            throw HIDSessionFailure("device_ambiguous", "未发现唯一的支持遥控器；未选择其他键盘。")
        }
        guard snapshot.registryID == registryID, snapshot.locationID == locationID else {
            throw HIDSessionFailure("device_changed", "遥控器与本次确认的本机绑定不同；未自动替换。")
        }
        return try operation(service, snapshot)
    }
}

enum HIDSessionPeer {
    static let app = HIDInstalledHelperContract.applicationPath
    static let executable = app + "/Contents/MacOS/OpenRemoteAssistant"
    static let helperBundle = HIDInstalledHelperContract.helperBundlePath
    static let helper = HIDInstalledHelperContract.helperExecutablePath
    static let helperIdentifier = HIDInstalledHelperContract.helperIdentifier

    /// Every invocation (including ordinary-user permission IPC)
    /// proves that it is the pinned helper inside the fixed installation.
    static func validateInstalledHelper() throws {
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw HIDSessionFailure("application_identity", "无法核验安装根目录。") }
        defer { close(directory) }
        for component in ["Applications", "遥控器助手.app", "Contents"] {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HIDSessionFailure("application_identity", "安装路径缺失或含符号链接。") }
            do { try validateOwnership(fd: next, applications: component == "Applications") }
            catch { close(next); throw error }
            close(directory); directory = next
        }
        let plistFD = openat(directory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard plistFD >= 0 else { throw HIDSessionFailure("application_identity", "主程序身份文件缺失。") }
        defer { close(plistFD) }
        try validateOwnership(fd: plistFD, regular: true)
        let values = try readPlist(fd: plistFD)
        guard let expectedHash = HIDInstalledHelperContract.helperHash(fromApplicationInfo: values) else {
            throw HIDSessionFailure("application_identity", "主程序安装身份、版本或按键辅助哈希无效。")
        }

        // The nested copy is a signed installer payload. It must be the same
        // pinned bytes, but neither ordinary nor root modes ever execute it.
        let helpers = openat(directory, "Helpers", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard helpers >= 0 else { throw HIDSessionFailure("application_identity", "按键辅助目录缺失或含符号链接。") }
        defer { close(helpers) }
        try validateOwnership(fd: helpers)
        let packaged = openat(helpers, "OpenRemoteHIDCoreService.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard packaged >= 0 else { throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板缺失或含符号链接。") }
        defer { close(packaged) }
        try validateOwnership(fd: packaged)
        let packagedContents = openat(packaged, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard packagedContents >= 0 else { throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板 Contents 无效。") }
        defer { close(packagedContents) }
        try validateOwnership(fd: packagedContents)
        let packagedInfo = openat(packagedContents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard packagedInfo >= 0 else { throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板身份文件缺失。") }
        defer { close(packagedInfo) }
        try validateOwnership(fd: packagedInfo, regular: true)
        guard HIDInstalledHelperContract.validServiceInfo(try readPlist(fd: packagedInfo)) else {
            throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板的 bundle 身份或版本无效。")
        }
        let packagedMacOS = openat(packagedContents, "MacOS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard packagedMacOS >= 0 else { throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板可执行目录无效。") }
        defer { close(packagedMacOS) }
        try validateOwnership(fd: packagedMacOS)
        let packagedExecutable = openat(packagedMacOS, "OpenRemoteHIDCoreService", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard packagedExecutable >= 0 else { throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板文件缺失。") }
        defer { close(packagedExecutable) }
        try validateOwnership(fd: packagedExecutable, regular: true)
        var packagedStat = stat()
        guard fstat(packagedExecutable, &packagedStat) == 0, packagedStat.st_size > 0,
              packagedStat.st_size <= 8 * 1_048_576,
              try sha256(fd: packagedExecutable, size: Int(packagedStat.st_size)) == expectedHash else {
            throw HIDSessionFailure("helper_identity", "遥控器按键服务安装模板与主程序固定哈希不一致。")
        }

        // Only this root-protected bundle is executable. Every component is
        // opened without following links and rejects writable ACLs.
        var protectedDirectory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard protectedDirectory >= 0 else { throw HIDSessionFailure("helper_identity", "无法核验受保护按键服务根目录。") }
        defer { close(protectedDirectory) }
        try validateProtected(fd: protectedDirectory, permissions: 0o755)
        for component in ["Library", "PrivilegedHelperTools", "OpenRemoteHIDCoreService.app", "Contents"] {
            let next = openat(protectedDirectory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HIDSessionFailure("helper_identity", "受保护按键服务路径缺失或含符号链接。") }
            do { try validateProtected(fd: next, permissions: 0o755) }
            catch { close(next); throw error }
            close(protectedDirectory); protectedDirectory = next
        }
        let serviceInfo = openat(protectedDirectory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard serviceInfo >= 0 else { throw HIDSessionFailure("helper_identity", "受保护按键服务身份文件缺失。") }
        defer { close(serviceInfo) }
        try validateProtected(fd: serviceInfo, regular: true, permissions: 0o644)
        guard HIDInstalledHelperContract.validServiceInfo(try readPlist(fd: serviceInfo)) else {
            throw HIDSessionFailure("helper_identity", "受保护按键服务的 bundle 身份或版本无效。")
        }
        let serviceMacOS = openat(protectedDirectory, "MacOS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard serviceMacOS >= 0 else { throw HIDSessionFailure("helper_identity", "受保护按键服务可执行目录无效。") }
        defer { close(serviceMacOS) }
        try validateProtected(fd: serviceMacOS, permissions: 0o755)
        let helperFD = openat(serviceMacOS, "OpenRemoteHIDCoreService", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard helperFD >= 0 else { throw HIDSessionFailure("helper_identity", "受保护按键服务文件缺失或含符号链接。") }
        defer { close(helperFD) }
        try validateProtected(fd: helperFD, regular: true, permissions: 0o755)
        var before = stat(), pathValue = stat(), after = stat()
        var processPath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard fstat(helperFD, &before) == 0, before.st_size > 0, before.st_size <= 8 * 1_048_576,
              proc_pidpath(getpid(), &processPath, UInt32(processPath.count)) > 0,
              String(cString: processPath) == helper,
              lstat(helper, &pathValue) == 0, same(before, pathValue),
              try sha256(fd: helperFD, size: Int(before.st_size)) == expectedHash,
              fstat(helperFD, &after) == 0, same(before, after) else {
            throw HIDSessionFailure("helper_identity", "当前进程不是固定安装且哈希匹配的按键辅助程序。")
        }
        var appCode: SecStaticCode?, packagedCode: SecStaticCode?, helperCode: SecStaticCode?
        var appRequirement: SecRequirement?, helperRequirement: SecRequirement?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecRequirementCreateWithString("identifier \"org.rc001remote.assistant\"" as CFString,
                  SecCSFlags(), &appRequirement) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"\(helperIdentifier)\"" as CFString,
                  SecCSFlags(), &helperRequirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, SecCSFlags(), &appCode) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: HIDInstalledHelperContract.packagedHelperBundlePath) as CFURL,
                  SecCSFlags(), &packagedCode) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: helperBundle) as CFURL, SecCSFlags(), &helperCode) == errSecSuccess,
              let appCode, let packagedCode, let helperCode, let appRequirement, let helperRequirement,
              SecStaticCodeCheckValidity(appCode, strict, appRequirement) == errSecSuccess,
              SecStaticCodeCheckValidity(packagedCode, strict, helperRequirement) == errSecSuccess,
              SecStaticCodeCheckValidity(helperCode, strict, helperRequirement) == errSecSuccess else {
            throw HIDSessionFailure("helper_signature", "主程序或按键辅助程序的固定签名身份无效。")
        }
    }

    static func validateSocket(_ arguments: HIDSessionArguments) throws {
        try validateSocket(path: arguments.socketPath, uid: arguments.clientUID)
    }

    static func validatePermissionSocket(_ arguments: HIDPermissionArguments) throws {
        try validateSocket(path: arguments.socketPath, uid: arguments.clientUID)
    }

    private static func validateSocket(path: String, uid: UInt32) throws {
        let parent = (path as NSString).deletingLastPathComponent
        var directory = stat(), endpoint = stat()
        guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == uid, directory.st_mode & 0o777 == 0o700,
              lstat(path, &endpoint) == 0, endpoint.st_mode & S_IFMT == S_IFSOCK,
              endpoint.st_uid == uid, endpoint.st_mode & 0o777 == 0o600,
              endpoint.st_nlink == 1 else { throw HIDSessionFailure("socket_identity", "按键通信端点不是该用户的私有套接字。") }
        for fixed in ["/private", "/private/var", "/private/var/tmp"] {
            var item = stat()
            guard lstat(fixed, &item) == 0, item.st_mode & S_IFMT == S_IFDIR, item.st_uid == 0,
                  (fixed == "/private/var/tmp" ? item.st_mode & S_ISVTX != 0 : item.st_mode & 0o022 == 0) else {
                throw HIDSessionFailure("socket_identity", "系统临时目录身份或权限异常。")
            }
        }
    }

    static func validate(fd: Int32, arguments: HIDSessionArguments) throws -> HIDSessionClientIdentity {
        try validateClient(fd: fd, pid: arguments.clientPID, uid: arguments.clientUID)
    }

    static func validatePermission(fd: Int32, arguments: HIDPermissionArguments) throws -> HIDPermissionClientIdentity {
        let firstToken = try permissionPeerToken(fd: fd, pid: arguments.clientPID, uid: arguments.clientUID)
        let firstData = withUnsafeBytes(of: firstToken) { Data($0) }
        let first = try identity(pid: arguments.clientPID, uid: arguments.clientUID)
        try validateApplication(pid: arguments.clientPID, auditToken: firstData)
        let secondToken = try permissionPeerToken(fd: fd, pid: arguments.clientPID, uid: arguments.clientUID)
        let secondData = withUnsafeBytes(of: secondToken) { Data($0) }
        let second = try identity(pid: arguments.clientPID, uid: arguments.clientUID)
        let pidVersion = audit_token_to_pidversion(secondToken)
        guard first == second, firstData == secondData, pidVersion > 0 else {
            throw HIDSessionFailure("peer_changed", "主程序身份在输入监控请求核验期间发生变化。")
        }
        return .init(process: second, auditToken: secondData, pidVersion: pidVersion)
    }

    private static func permissionPeerToken(fd: Int32, pid expectedPID: Int32,
                                            uid expectedUID: UInt32) throws -> audit_token_t {
        var uid: uid_t = 0, gid: gid_t = 0, token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size,
              audit_token_to_pid(token) == expectedPID,
              audit_token_to_euid(token) == expectedUID,
              audit_token_to_ruid(token) == expectedUID,
              audit_token_to_pidversion(token) > 0,
              uid == expectedUID else {
            throw HIDSessionFailure("peer_identity", "输入监控通信对端不是已确认的普通用户主程序。")
        }
        return token
    }

    private static func validateClient(fd: Int32, pid expectedPID: Int32,
                                       uid expectedUID: UInt32) throws -> HIDSessionClientIdentity {
        var uid: uid_t = 0, gid: gid_t = 0, token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size,
              audit_token_to_pid(token) == expectedPID,
              audit_token_to_euid(token) == expectedUID,
              audit_token_to_ruid(token) == expectedUID,
              uid == expectedUID else {
            throw HIDSessionFailure("peer_identity", "按键通信对端不是已确认的普通用户主程序。")
        }
        let first = try identity(pid: expectedPID, uid: expectedUID)
        try validateApplication(pid: expectedPID)
        let second = try identity(pid: expectedPID, uid: expectedUID)
        guard first == second else { throw HIDSessionFailure("peer_changed", "主程序身份在核验期间改变。") }
        return second
    }

    static func identity(pid: Int32, uid: UInt32) throws -> HIDSessionClientIdentity {
        var info = kinfo_proc(), mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        guard pid > 1, uid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
              info.kp_eproc.e_ucred.cr_uid == uid, info.kp_eproc.e_pcred.p_ruid == uid,
              info.kp_eproc.e_pcred.p_svuid == uid,
              info.kp_proc.p_un.__p_starttime.tv_sec > 0,
              info.kp_proc.p_un.__p_starttime.tv_usec >= 0,
              info.kp_proc.p_un.__p_starttime.tv_usec < 1_000_000 else {
            throw HIDSessionFailure("peer_identity", "无法确认主程序的账户或启动时间。")
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable else {
            throw HIDSessionFailure("peer_identity", "按键辅助进程只接受固定安装位置的主程序。")
        }
        return .init(pid: pid, uid: uid, realUID: info.kp_eproc.e_pcred.p_ruid, savedUID: info.kp_eproc.e_pcred.p_svuid,
                     startSeconds: info.kp_proc.p_un.__p_starttime.tv_sec,
                     startMicroseconds: info.kp_proc.p_un.__p_starttime.tv_usec, path: String(cString: path))
    }

    static func validateApplication(pid: Int32, auditToken: Data? = nil) throws {
        let components = ["Applications", "遥控器助手.app", "Contents"]
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw HIDSessionFailure("application_identity", "无法核验安装目录。") }
        defer { close(directory) }
        for component in components {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HIDSessionFailure("application_identity", "安装路径缺失或含符号链接。") }
            do { try validateOwnership(fd: next, applications: component == "Applications") }
            catch { close(next); throw error }
            close(directory); directory = next
        }
        let plistFD = openat(directory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard plistFD >= 0 else { throw HIDSessionFailure("application_identity", "主程序身份文件缺失。") }
        defer { close(plistFD) }
        try validateOwnership(fd: plistFD, regular: true)
        var infoStat = stat()
        guard fstat(plistFD, &infoStat) == 0, infoStat.st_size > 0, infoStat.st_size <= 1_048_576 else {
            throw HIDSessionFailure("application_identity", "主程序身份文件长度异常。")
        }
        var data = Data(count: Int(infoStat.st_size))
        let readCount = data.withUnsafeMutableBytes { pread(plistFD, $0.baseAddress, $0.count, 0) }
        guard readCount == data.count,
              let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              values["CFBundleIdentifier"] as? String == HIDInstalledHelperContract.applicationIdentifier,
              values["CFBundleExecutable"] as? String == "OpenRemoteAssistant",
              values["CFBundleShortVersionString"] as? String == HIDInstalledHelperContract.version,
              values["CFBundleVersion"] as? String == HIDInstalledHelperContract.build else {
            throw HIDSessionFailure("application_identity", "主程序安装身份或版本不匹配。")
        }
        let macOS = openat(directory, "MacOS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard macOS >= 0 else { throw HIDSessionFailure("application_identity", "主程序可执行目录无效。") }
        defer { close(macOS) }
        try validateOwnership(fd: macOS)
        let executableFD = openat(macOS, "OpenRemoteAssistant", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard executableFD >= 0 else { throw HIDSessionFailure("application_identity", "主程序可执行文件无效。") }
        defer { close(executableFD) }
        try validateOwnership(fd: executableFD, regular: true)
        var code: SecCode?, requirement: SecRequirement?
        let guestAttributes: [String: Any] = auditToken.map {
            [kSecGuestAttributeAudit as String: $0]
        } ?? [kSecGuestAttributePid as String: pid]
        guard SecCodeCopyGuestWithAttributes(nil, guestAttributes as CFDictionary, SecCSFlags(), &code) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"org.rc001remote.assistant\"" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let code, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw HIDSessionFailure("application_signature", "运行中的主程序代码签名未通过校验。")
        }
        var installed: SecStaticCode?, running: SecStaticCode?
        var installedInfo: CFDictionary?, runningInfo: CFDictionary?
        let signing = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, SecCSFlags(), &installed) == errSecSuccess,
              let installed,
              SecStaticCodeCheckValidity(installed, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              SecCodeCopyStaticCode(code, SecCSFlags(), &running) == errSecSuccess, let running,
              SecCodeCopySigningInformation(installed, signing, &installedInfo) == errSecSuccess,
              SecCodeCopySigningInformation(running, signing, &runningInfo) == errSecSuccess,
              let installedHash = (installedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let runningHash = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !installedHash.isEmpty, installedHash == runningHash else {
            throw HIDSessionFailure("application_signature", "运行中的主程序与完整安装包的签名身份不一致。")
        }
        var executableStat = stat(), currentExecutable = stat(), currentInfo = stat(), afterInfo = stat()
        guard fstat(executableFD, &executableStat) == 0, lstat(executable, &currentExecutable) == 0,
              fstat(plistFD, &afterInfo) == 0, lstat(app + "/Contents/Info.plist", &currentInfo) == 0,
              same(executableStat, currentExecutable), same(infoStat, afterInfo), same(infoStat, currentInfo) else {
            throw HIDSessionFailure("application_changed", "主程序安装文件在核验期间发生变化。")
        }
    }

    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
        first.st_uid == second.st_uid && first.st_gid == second.st_gid && first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
    }

    private static func readPlist(fd: Int32) throws -> [String: Any] {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size > 0, value.st_size <= 1_048_576 else {
            throw HIDSessionFailure("application_identity", "主程序身份文件长度异常。")
        }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count,
              let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw HIDSessionFailure("application_identity", "无法完整读取主程序身份文件。")
        }
        return result
    }

    private static func sha256(fd: Int32, size: Int) throws -> String {
        var hasher = SHA256(), offset = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < size {
            let wanted = min(buffer.count, size - offset)
            let count = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, wanted, off_t(offset))
            }
            guard count > 0 else { throw HIDSessionFailure("helper_identity", "无法完整读取按键辅助程序。") }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += count
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateOwnership(fd: Int32, applications: Bool = false, regular: Bool = false) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == 0,
              value.st_mode & S_IFMT == (regular ? S_IFREG : S_IFDIR),
              !regular || value.st_nlink == 1,
              applications ? (value.st_mode & 0o002 == 0 && value.st_gid == getgrnam("admin")?.pointee.gr_gid)
                           : value.st_mode & 0o022 == 0 else {
            throw HIDSessionFailure("application_permissions", "主程序安装文件权限不安全。")
        }
        try validateACL(fd: fd)
    }

    private static func validateProtected(fd: Int32, regular: Bool = false, permissions: mode_t) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else {
            throw HIDSessionFailure("helper_permissions", "受保护按键服务的所有权或权限不安全。")
        }
        let typeMatches = value.st_mode & S_IFMT == (regular ? S_IFREG : S_IFDIR)
        let accepted = permissions == 0o644
            ? HIDProtectedPathPolicy.acceptsInfo(owner: value.st_uid, group: value.st_gid,
                permissions: UInt16(value.st_mode & 0o777), typeMatches: typeMatches,
                links: UInt64(value.st_nlink))
            : HIDProtectedPathPolicy.accepts(owner: value.st_uid, group: value.st_gid,
                permissions: UInt16(value.st_mode & 0o777), typeMatches: typeMatches,
                regular: regular, links: UInt64(value.st_nlink))
        guard accepted else { throw HIDSessionFailure("helper_permissions", "受保护按键服务的所有权或权限不安全。") }
        try validateACL(fd: fd)
    }

    private static func validateACL(fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw HIDSessionFailure("application_permissions", "无法核实安装文件 ACL。")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw HIDSessionFailure("application_permissions", "安装文件 ACL 无效。") }
        var entry: acl_entry_t?, selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            errno = 0
            let result = acl_get_entry(acl, selector, &entry); selector = Int32(ACL_NEXT_ENTRY.rawValue)
            if result == -1 && errno == EINVAL { break }
            guard result == 0, let entry else { throw HIDSessionFailure("application_permissions", "安装文件 ACL 不完整。") }
            var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw HIDSessionFailure("application_permissions", "安装文件 ACL 无法解析。")
            }
            if tag == ACL_EXTENDED_ALLOW {
                for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                   ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    guard acl_get_perm_np(permissions, permission) == 0 else {
                        throw HIDSessionFailure("application_permissions", "安装文件 ACL 允许额外写入；拒绝特权读取会话。")
                    }
                }
            }
        }
    }
}
