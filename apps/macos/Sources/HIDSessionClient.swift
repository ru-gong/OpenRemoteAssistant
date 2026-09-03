// SPDX-License-Identifier: GPL-3.0-only
// The GUI remains unprivileged. A user-confirmed, fixed helper owns one RC003-MS
// for one mapping session. Only verified keyboard usages cross this local IPC.
import Foundation
import AppKit
import Darwin
import Security
import CryptoKit

struct HIDClientTarget: Equatable {
    let registryID: UInt64
    let locationID: Int
    var isValid: Bool { registryID > 0 && locationID >= 0 && UInt64(locationID) <= UInt64(UInt32.max) }
}

enum HIDClientMessage: Equatable {
    case ready, keys(Set<UInt16>), pong(UInt64), stopped(String), failure(code: String, message: String)
}

struct HIDClientDecoder {
    private var pending = Data()
    private var ready = false
    private var lastKeys: UInt64 = 0
    private var lastPong: UInt64 = 0
    let token: String
    let target: HIDClientTarget
    let allowedUsages: Set<UInt16>
    init(token: String, target: HIDClientTarget, allowedUsages: Set<UInt16>) {
        self.token = token; self.target = target; self.allowedUsages = allowedUsages
    }
    enum Invalid: Error { case frame }
    private struct Frame: Decodable {
        let type: String
        let version: Int?
        let token: String?
        let registryID: UInt64?
        let locationID: Int?
        let sequence: UInt64?
        let usages: [UInt16]?
        let reason: String?
        let code: String?
        let message: String?
    }
    mutating func receive(_ bytes: Data, lastPing: UInt64) throws -> [HIDClientMessage] {
        guard bytes.count <= 4096 else { throw Invalid.frame }
        pending.append(bytes)
        var messages: [HIDClientMessage] = []
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            try HIDSessionJSON.validateUniqueMembers(line)
            guard !line.isEmpty, line.count <= 1024,
                  let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let frame = try? JSONDecoder().decode(Frame.self, from: line) else { throw Invalid.frame }
            let fields = Set(object.keys)
            switch frame.type {
            case "ready":
                guard !ready, fields == ["type", "version", "token", "registryID", "locationID"],
                      frame.version == 1, frame.token == token,
                      frame.registryID == target.registryID, frame.locationID == target.locationID else { throw Invalid.frame }
                ready = true; messages.append(.ready)
            case "keys":
                guard ready, fields == ["type", "sequence", "usages"], let sequence = frame.sequence,
                      lastKeys < UInt64.max, sequence == lastKeys + 1, let values = frame.usages,
                      values.count <= 3, Set(values).count == values.count,
                      Set(values).isSubset(of: allowedUsages) else { throw Invalid.frame }
                lastKeys = sequence; messages.append(.keys(Set(values)))
            case "pong":
                guard ready, fields == ["type", "sequence"], let sequence = frame.sequence,
                      sequence > lastPong, sequence <= lastPing else { throw Invalid.frame }
                lastPong = sequence; messages.append(.pong(sequence))
            case "stopped":
                guard fields == ["type", "reason"], let reason = frame.reason, reason.utf8.count <= 256 else { throw Invalid.frame }
                messages.append(.stopped(reason))
            case "error":
                guard fields == ["type", "code", "message"], let code = frame.code, code.utf8.count <= 128,
                      let message = frame.message, message.utf8.count <= 768 else { throw Invalid.frame }
                let validCode = !code.isEmpty && code.utf8.count <= 64 && code.utf8.allSatisfy {
                    (48...57).contains($0) || (97...122).contains($0) || $0 == 95
                }
                guard validCode else { throw Invalid.frame }
                let safe = String(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
                messages.append(.failure(code: code, message: safe.isEmpty ? "按键辅助进程拒绝了本次会话。" : safe))
            default: throw Invalid.frame
            }
        }
        guard pending.count <= 1024 else { throw Invalid.frame }
        return messages
    }
}

struct HIDSessionReportedFailure: Equatable {
    let code: String
    let message: String
}

enum HIDSessionAuthorizationEnvelope {
    static func failure(_ data: Data) -> HIDSessionReportedFailure? {
        let line = data.last == 10 ? Data(data.dropLast()) : data
        guard (try? HIDSessionJSON.validateUniqueMembers(line)) != nil,
              let outer = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(outer.keys) == ["helperExit", "cleanupSucceeded", "result"],
              let exit = outer["helperExit"] as? NSNumber,
              CFGetTypeID(exit) != CFBooleanGetTypeID(), exit.intValue > 0, exit.intValue <= 255,
              outer["cleanupSucceeded"] as? Bool == true,
              let result = outer["result"] as? [String: Any],
              Set(result.keys) == ["success", "code", "message"],
              let succeeded = result["success"] as? NSNumber,
              CFGetTypeID(succeeded) == CFBooleanGetTypeID(), !succeeded.boolValue,
              let code = result["code"] as? String, code.utf8.count <= 64,
              !code.isEmpty, code.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 95 }),
              let message = result["message"] as? String, message.utf8.count <= 768 else { return nil }
        let safe = String(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
        return .init(code: code, message: safe.isEmpty ? "按键辅助进程拒绝了本次会话。" : safe)
    }
}

struct HIDHelperPeer: Equatable {
    let pid: pid_t
    let uid: uid_t
    let realUID: uid_t
    let savedUID: uid_t
    let seconds: Int
    let microseconds: Int
    let path: String
    enum Reading { case absent, identity(HIDHelperPeer), unknown }
    static func read(_ pid: pid_t) -> Reading {
        guard pid > 1 else { return .unknown }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        errno = 0
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        if result == 0 && size == 0 || result != 0 && errno == ESRCH { return .absent }
        guard result == 0, size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid,
              info.kp_proc.p_un.__p_starttime.tv_sec > 0 else { return .unknown }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return .unknown }
        return .identity(.init(pid: pid, uid: info.kp_eproc.e_ucred.cr_uid,
            realUID: info.kp_eproc.e_pcred.p_ruid, savedUID: info.kp_eproc.e_pcred.p_svuid,
            seconds: info.kp_proc.p_un.__p_starttime.tv_sec,
            microseconds: Int(info.kp_proc.p_un.__p_starttime.tv_usec), path: String(cString: path)))
    }
}

/// Ordinary-user validation of the only executable path used by both modes.
/// Because every ancestor below / is root:wheel 0755 with no writable ACL,
/// another ordinary/admin-group process cannot replace the checked inode
/// between this validation and Process/authorization execution.
enum HIDProtectedHelperValidation {
    static let failure = "受保护的遥控器按键服务文件、权限或校验值不符，请先用完整安装包修复。未执行服务、未请求管理员授权。"

    static func validationError(expectedDigest: String) -> String? {
        guard HIDSessionRules.isHex(expectedDigest, count: 64) else { return failure }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return failure }
        defer { close(directory) }
        guard validDirectory(directory) else { return failure }
        for component in ["Library", "PrivilegedHelperTools", "OpenRemoteHIDCoreService.app", "Contents"] {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return failure }
            guard validDirectory(next) else { close(next); return failure }
            close(directory); directory = next
        }
        let infoFD = openat(directory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard infoFD >= 0 else { return failure }
        defer { close(infoFD) }
        guard validRegular(infoFD, permissions: 0o644), validInfo(infoFD) else { return failure }
        let macOS = openat(directory, "MacOS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard macOS >= 0 else { return failure }
        defer { close(macOS) }
        guard validDirectory(macOS) else { return failure }
        let executable = openat(macOS, "OpenRemoteHIDCoreService", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard executable >= 0 else { return failure }
        defer { close(executable) }
        var before = stat(), after = stat(), path = stat()
        guard validRegular(executable, permissions: 0o755), fstat(executable, &before) == 0,
              before.st_size > 0, before.st_size <= 8 * 1_048_576,
              digest(executable, size: Int(before.st_size)) == expectedDigest,
              fstat(executable, &after) == 0,
              lstat(HIDInstalledHelperContract.helperExecutablePath, &path) == 0,
              same(before, after), same(before, path) else { return failure }
        return nil
    }

    private static func validDirectory(_ fd: Int32) -> Bool {
        var value = stat()
        return fstat(fd, &value) == 0 &&
            HIDProtectedPathPolicy.accepts(owner: value.st_uid, group: value.st_gid,
                permissions: UInt16(value.st_mode & 0o777),
                typeMatches: value.st_mode & S_IFMT == S_IFDIR, regular: false,
                links: UInt64(value.st_nlink)) && validACL(fd)
    }

    private static func validRegular(_ fd: Int32, permissions: UInt16) -> Bool {
        var value = stat()
        guard fstat(fd, &value) == 0 else { return false }
        let metadata: Bool
        if permissions == 0o644 {
            metadata = HIDProtectedPathPolicy.acceptsInfo(owner: value.st_uid, group: value.st_gid,
                permissions: UInt16(value.st_mode & 0o777), typeMatches: value.st_mode & S_IFMT == S_IFREG,
                links: UInt64(value.st_nlink))
        } else {
            metadata = HIDProtectedPathPolicy.accepts(owner: value.st_uid, group: value.st_gid,
                permissions: UInt16(value.st_mode & 0o777), typeMatches: value.st_mode & S_IFMT == S_IFREG,
                regular: true, links: UInt64(value.st_nlink))
        }
        return metadata && validACL(fd)
    }

    private static func validInfo(_ fd: Int32) -> Bool {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size > 0, value.st_size <= 1_048_576 else { return false }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count,
              let fields = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return false }
        return HIDInstalledHelperContract.validServiceInfo(fields)
    }

    private static func validACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?, selector = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            errno = 0
            let result = acl_get_entry(acl, selector, &entry); selector = Int32(ACL_NEXT_ENTRY.rawValue)
            if result == -1 && errno == EINVAL { return true }
            guard result == 0, let entry else { return false }
            var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0,
                  let permissions else { return false }
            if tag == ACL_EXTENDED_ALLOW {
                for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                   ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
                where acl_get_perm_np(permissions, permission) != 0 { return false }
            }
        }
    }

    private static func digest(_ fd: Int32, size: Int) -> String? {
        var hasher = SHA256(), offset = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < size {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, min($0.count, size - offset), off_t(offset)) }
            guard count > 0 else { return nil }
            hasher.update(data: Data(buffer.prefix(count))); offset += count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode &&
        lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_nlink == rhs.st_nlink &&
        lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

/// The permission-only helper is started through NSWorkspace so macOS can
/// attribute Input Monitoring to its application bundle. argv identifies only
/// the private IPC endpoint and main-app peer; it never selects an operation or
/// exposes a result path, nonce or authentication secret.
enum HIDPermissionLaunchPlan {
    static let helperBundlePath = HIDInstalledHelperContract.helperBundlePath
    static func validSocketPath(_ path: String, uid: uid_t) -> Bool {
        path.range(of: "^/private/var/tmp/OpenRemote-HID-Permission-\(uid)-[0-9a-f]{32}/permission\\.sock$",
                   options: .regularExpression) != nil && path.utf8.count < 104
    }

    static func arguments(socketPath: String, clientPID: pid_t, clientUID: uid_t) throws -> [String] {
        guard clientPID > 1, clientUID > 0, validSocketPath(socketPath, uid: clientUID) else {
            throw HIDClientDecoder.Invalid.frame
        }
        return ["--permission-ipc", "--socket", socketPath,
                "--client-pid", String(clientPID), "--client-uid", String(clientUID)]
    }
}

/// Timeout and cancellation may resolve the caller-facing result, but the
/// operation gate stays held until NSWorkspace confirms termination of the
/// exact process instance returned by openApplication. This preserves the P1
/// fail-closed lifecycle without relying on an `open -W` proxy process.
struct HIDPermissionWaiterLifecycle: Equatable {
    private(set) var timedOut = false
    private(set) var cancelled = false
    private(set) var helperExitConfirmed = false
    private(set) var outcomeClaimed = false

    var mustHoldGate: Bool { !helperExitConfirmed }
    var mayComplete: Bool { helperExitConfirmed }

    /// Returns true exactly once when the timeout should be reported.
    mutating func markTimedOut() -> Bool {
        guard !timedOut else { return false }
        timedOut = true
        return claimOutcome()
    }

    /// Cancellation suppresses the permission callback but cannot release the
    /// lifecycle gate while the launched helper may still exist.
    mutating func markCancelled() {
        cancelled = true
        outcomeClaimed = true
    }

    mutating func recordApplicationTermination() { helperExitConfirmed = true }

    /// Claims a non-cancelled caller-facing result without releasing the gate.
    mutating func claimOutcome() -> Bool {
        guard !outcomeClaimed, !cancelled else { return false }
        outcomeClaimed = true
        return true
    }
}

enum HIDPermissionPeerPolicy {
    static func accepts(expectedPID: pid_t, expectedUID: uid_t, expectedPath: String,
                        peerPID: pid_t, peerEUID: uid_t, peerRUID: uid_t,
                        identity: HIDHelperPeer) -> Bool {
        expectedPID > 1 && expectedUID > 0 && peerPID == expectedPID &&
            peerEUID == expectedUID && peerRUID == expectedUID &&
            identity.pid == expectedPID && identity.uid == expectedUID &&
            identity.realUID == expectedUID && identity.savedUID == expectedUID &&
            identity.path == expectedPath
    }
}

/// A transient process-table read failure is not evidence that the exact
/// LaunchServices helper has exited. Only absence or a changed process
/// identity may release the permission-operation gate.
enum HIDPermissionProcessObservationPolicy {
    static func confirmsExit(_ reading: HIDHelperPeer.Reading, expected: HIDHelperPeer) -> Bool {
        switch reading {
        case .absent: return true
        case .identity(let current): return current != expected
        case .unknown: return false
        }
    }
}

/// Binds a connected stream to the exact NSRunningApplication instance and
/// then proves that its live code is the fixed root-protected helper bytes.
enum HIDPermissionHelperPeerValidation {
    static func validate(fd: Int32, expected: HIDHelperPeer) -> Bool {
        var uid: uid_t = UInt32.max, gid: gid_t = UInt32.max, token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size,
              case .identity(let first) = HIDHelperPeer.read(expected.pid), first == expected,
              HIDPermissionPeerPolicy.accepts(expectedPID: expected.pid, expectedUID: expected.uid,
                  expectedPath: HIDInstalledHelperContract.helperExecutablePath,
                  peerPID: audit_token_to_pid(token), peerEUID: audit_token_to_euid(token),
                  peerRUID: audit_token_to_ruid(token), identity: first), uid == expected.uid,
              validCode(pid: expected.pid),
              case .identity(let second) = HIDHelperPeer.read(expected.pid), second == expected else { return false }
        return true
    }

    private static func validCode(pid: pid_t) -> Bool {
        var running: SecCode?, runningStatic: SecStaticCode?, installed: SecStaticCode?
        var requirement: SecRequirement?, runningInfo: CFDictionary?, installedInfo: CFDictionary?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        let installedStrict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let signing = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecRequirementCreateWithString("identifier \"\(HIDInstalledHelperContract.helperIdentifier)\"" as CFString,
                  SecCSFlags(), &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary,
                  SecCSFlags(), &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, strict, requirement) == errSecSuccess,
              SecCodeCopyStaticCode(running, SecCSFlags(), &runningStatic) == errSecSuccess, let runningStatic,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: HIDInstalledHelperContract.helperBundlePath) as CFURL,
                  SecCSFlags(), &installed) == errSecSuccess, let installed,
              SecStaticCodeCheckValidity(installed, installedStrict, requirement) == errSecSuccess,
              SecCodeCopySigningInformation(runningStatic, signing, &runningInfo) == errSecSuccess,
              SecCodeCopySigningInformation(installed, signing, &installedInfo) == errSecSuccess,
              let liveHash = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let diskHash = (installedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !liveHash.isEmpty, liveHash == diskHash else { return false }
        return true
    }
}

enum HIDSessionScriptBuilder {
    static let helperPath = HIDInstalledHelperContract.helperExecutablePath
    static func validSocketPath(_ path: String, uid: uid_t) -> Bool {
        path.range(of: "^/private/var/tmp/OpenRemote-HID-\(uid)-[0-9a-f]{32}/session\\.sock$", options: .regularExpression) != nil
            && path.utf8.count < 104
    }
    static func shellScript(digest: String, socket: String, token: String, pid: pid_t,
                            uid: uid_t, target: HIDClientTarget) throws -> String {
        func hex(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        guard hex(digest), hex(token), pid > 1, uid > 0, target.isValid, validSocketPath(socket, uid: uid) else {
            throw HIDClientDecoder.Invalid.frame
        }
        // Every interpolation is a validated numeric value, lowercase hex or
        // fixed-pattern socket path. No arbitrary executable or shell input.
        return """
        set -eu
        umask 077
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        LANG=C
        LC_ALL=C
        export PATH LANG LC_ALL
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for protected_dir in '/Library' '/Library/PrivilegedHelperTools' '/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app' '/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents' '/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents/MacOS'; do
            [ ! -L "$protected_dir" ] && [ -d "$protected_dir" ] || exit 74
            protected_metadata=$(/usr/bin/stat -f '%u:%g:%Lp' "$protected_dir")
            [ "$protected_metadata" = '0:0:755' ] || exit 74
        done
        [ ! -L '\(helperPath)' ] && [ -f '\(helperPath)' ] || exit 74
        metadata=$(/usr/bin/stat -f '%u:%g:%Lp:%l' '\(helperPath)')
        [ "$metadata" = '0:0:755:1' ] || exit 74
        actual=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum -a 256 '\(helperPath)')
        [ "${actual%% *}" = '\(digest)' ] || exit 74
        result=0
        result_json=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C '\(helperPath)' --session --socket '\(socket)' --client-pid \(pid) --client-uid \(uid) --token '\(token)' --registry-id \(target.registryID) --location-id \(target.locationID)) || result=$?
        if [ -z "$result_json" ] || [ "${#result_json}" -gt 2000 ]; then result_json=null; fi
        /usr/bin/printf '{"helperExit":%s,"cleanupSucceeded":true,"result":%s}\\n' "$result" "$result_json"
        exit 0
        """
    }
    static func appleScript(digest: String, socket: String, token: String, pid: pid_t,
                            uid: uid_t, target: HIDClientTarget) throws -> Data {
        let shell = try shellScript(digest: digest, socket: socket, token: token, pid: pid, uid: uid, target: target)
        let expression = shell.components(separatedBy: "\n").map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " & linefeed & ")
        return Data("return do shell script (\(expression)) with administrator privileges without altering line endings\n".utf8)
    }
}

/// Main-thread state, nonblocking socket IO and an independent root-side
/// heartbeat deadline. No persistent service or saved administrator credential.
final class HIDSessionClient {
    enum Phase { case idle, validating, authorizing, active, stopping }
    var onChange: ((Phase, String) -> Void)?
    var onReady: ((HIDClientTarget) -> Void)?
    var onKeys: ((Set<UInt16>) -> Void)?
    var onStopped: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSessionFailure: ((String, String) -> Void)?
    private(set) var phase: Phase = .idle
    private(set) var isCheckingInputAccess = false
    var isPending: Bool { phase == .validating || phase == .authorizing || phase == .stopping }
    var isRunning: Bool { phase != .idle }
    private var generation: UInt64 = 0
    private var session: Session?
    private var stoppedHandlers: [() -> Void] = []
    private var permissionGate = HIDPermissionCompletionGate()
    private var permissionOperation: PermissionOperation?
    private final class PermissionOperation {
        let generation: UInt64
        let operation: HIDPermissionOperation
        let completion: (HIDInputAccessStatus, String) -> Void
        var nonce = "", challenge = "", directoryPath = "", socketPath = ""
        var directoryInode: ino_t = 0, socketInode: ino_t = 0
        var listener: Int32 = -1, connection: Int32 = -1
        var listenerSource: DispatchSourceRead?, connectionSource: DispatchSourceRead?
        var pendingConnections: [Int32] = []
        var lines = HIDSessionLineBuffer()
        var application: NSRunningApplication?
        var expectedPeer: HIDHelperPeer?
        var terminatedPIDs: Set<pid_t> = []
        var terminationObserver: NSObjectProtocol?
        var processTimer: Timer?
        var response: HIDPermissionResponse?
        var launchStarted = false, requestSent = false, ipcClosed = false
        var rejectedConnections = 0
        var lifecycle = HIDPermissionWaiterLifecycle()
        init(generation: UInt64, operation: HIDPermissionOperation,
             completion: @escaping (HIDInputAccessStatus, String) -> Void) {
            self.generation = generation; self.operation = operation; self.completion = completion
        }
    }
    private final class Session {
        let target: HIDClientTarget, token: String, path: String
        var decoder: HIDClientDecoder
        var listener: Int32 = -1, connection: Int32 = -1
        var listenerSource: DispatchSourceRead?, connectionSource: DispatchSourceRead?
        var timer: Timer?, process: Process?
        var input: Pipe?
        var errorCapture = Data(), outputCapture = Data()
        var errorEOF = false, outputEOF = false
        var exitStatus: Int32?
        var errorPipe: Pipe?, outputPipe: Pipe?
        var deadline = ProcessInfo.processInfo.systemUptime + 120
        var lastReply = ProcessInfo.processInfo.systemUptime
        var ping: UInt64 = 0, rejects = 0
        var closed = false, notified = false
        var peer: HIDHelperPeer?
        var peerReleased = false
        var closingDeadline = 0.0
        var socketInode: ino_t = 0
        init(target: HIDClientTarget, token: String, path: String, allowed: Set<UInt16>) {
            self.target = target; self.token = token; self.path = path
            decoder = HIDClientDecoder(token: token, target: target, allowedUsages: allowed)
        }
    }
    func start(target: HIDClientTarget, helperDigest: String?, allowedUsages: Set<UInt16>) {
        precondition(Thread.isMainThread)
        guard HIDOperationArbitration.canStartSession(hidIdle: phase == .idle,
                                                      permissionActive: permissionOperation != nil) else {
            onFailure?("输入监控检查或按键会话仍在进行，未启动新的管理员会话。")
            return
        }
        guard getuid() > 0, getuid() == geteuid(), target.isValid else { onFailure?("请以普通用户运行，并先绑定遥控器。"); return }
        generation &+= 1
        let token = generation, digest = (helperDigest ?? "").lowercased()
        change(.validating, "正在检查按键辅助进程；尚未接管遥控器。")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let error = HIDProtectedHelperValidation.validationError(expectedDigest: digest)
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.phase == .validating else { return }
                if let error {
                    self.change(.idle, "按键辅助进程未就绪。")
                    self.onFailure?(error.replacingOccurrences(of: "音频服务", with: "按键辅助")); return
                }
                self.launch(target: target, digest: digest, allowed: allowedUsages)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == token, self.phase == .validating else { return }
            self.generation &+= 1; self.change(.idle, "按键辅助进程校验超时，未请求授权。")
            self.onFailure?("按键辅助进程校验超时，请检查完整安装。未接管设备。")
        }
    }

    func checkInputAccess(helperDigest: String?, completion: @escaping (HIDInputAccessStatus, String) -> Void) {
        beginInputAccess(request: false, helperDigest: helperDigest, completion: completion)
    }

    func requestInputAccess(helperDigest: String?, completion: @escaping (HIDInputAccessStatus, String) -> Void) {
        beginInputAccess(request: true, helperDigest: helperDigest, completion: completion)
    }

    private func beginInputAccess(request: Bool, helperDigest: String?,
                                  completion: @escaping (HIDInputAccessStatus, String) -> Void) {
        precondition(Thread.isMainThread)
        guard HIDOperationArbitration.canStartPermission(hidIdle: phase == .idle,
                 permissionActive: permissionOperation != nil), getuid() > 0, getuid() == geteuid() else {
            DispatchQueue.main.async { completion(.unknown, "按键会话或另一项权限检查仍在进行，未启动新的辅助进程。") }
            return
        }
        let operation = PermissionOperation(generation: permissionGate.begin(),
            operation: request ? .request : .check, completion: completion)
        permissionOperation = operation; isCheckingInputAccess = true
        let digest = (helperDigest ?? "").lowercased()
        DispatchQueue.global(qos: .utility).async { [weak self, weak operation] in
            let failure = HIDProtectedHelperValidation.validationError(expectedDigest: digest)
            DispatchQueue.main.async {
                guard let self, let operation, self.permissionOperation === operation else { return }
                if let failure {
                    self.finishPermission(operation, status: .unknown,
                        message: failure.replacingOccurrences(of: "音频服务", with: "按键辅助"))
                } else {
                    self.launchPermission(operation, request: request)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak operation] in
            guard let self, let operation, self.permissionOperation === operation, !operation.launchStarted else { return }
            self.finishPermission(operation, status: .unknown, message: "按键辅助进程校验超时；未检查或请求输入监控授权。")
        }
    }

    private func launchPermission(_ operation: PermissionOperation, request: Bool) {
        guard permissionOperation === operation else { return }
        operation.launchStarted = true
        guard operation.operation == (request ? .request : .check) else {
            finishPermission(operation, status: .unknown, message: "输入监控请求状态不一致；未启动辅助进程。")
            return
        }
        let arguments: [String]
        do {
            var random = [UInt8](repeating: 0, count: 48)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw HIDClientDecoder.Invalid.frame
            }
            let folder = random.prefix(16).map { String(format: "%02x", $0) }.joined()
            operation.nonce = random.suffix(32).map { String(format: "%02x", $0) }.joined()
            operation.directoryPath = "/private/var/tmp/OpenRemote-HID-Permission-\(getuid())-\(folder)"
            operation.socketPath = operation.directoryPath + "/permission.sock"
            guard mkdir(operation.directoryPath, 0o700) == 0 else { throw HIDClientDecoder.Invalid.frame }
            var directory = stat()
            guard lstat(operation.directoryPath, &directory) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
                  directory.st_mode & 0o777 == 0o700 else { throw HIDClientDecoder.Invalid.frame }
            operation.directoryInode = directory.st_ino
            arguments = try HIDPermissionLaunchPlan.arguments(socketPath: operation.socketPath,
                clientPID: getpid(), clientUID: getuid())
            guard createPermissionListener(operation) else { throw HIDClientDecoder.Invalid.frame }
        } catch {
            finishPermission(operation, status: .unknown,
                message: "无法建立按键权限检查的私有认证通道；未检查或请求输入监控授权。")
            return
        }

        operation.terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self, weak operation] notification in
            guard let self, let operation, self.permissionOperation === operation,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.isFixedPermissionApplication(application) else { return }
            if let expected = operation.application {
                guard application.processIdentifier == expected.processIdentifier else { return }
                self.permissionApplicationTerminated(operation)
            } else if operation.terminatedPIDs.count < 16 {
                operation.terminatedPIDs.insert(application.processIdentifier)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = arguments
        configuration.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: HIDPermissionLaunchPlan.helperBundlePath),
            configuration: configuration) { [weak self, weak operation] application, error in
            DispatchQueue.main.async {
                guard let self, let operation, self.permissionOperation === operation else { return }
                guard error == nil, let application else {
                    operation.lifecycle.recordApplicationTermination()
                    self.permissionFinished(operation, fallback: "LaunchServices 未能启动固定按键辅助进程；未检查或请求输入监控授权。")
                    return
                }
                operation.application = application
                guard self.isFixedPermissionApplication(application), application.processIdentifier > 1 else {
                    self.closePermissionIPC(operation)
                    if operation.lifecycle.claimOutcome() {
                        self.deliverPermissionOutcomeKeepingGate(operation, status: .unknown,
                            message: "LaunchServices 返回的按键辅助进程身份不符；不会发送输入监控请求。")
                    }
                    _ = application.terminate()
                    self.startPermissionProcessTimer(operation)
                    return
                }
                switch HIDHelperPeer.read(application.processIdentifier) {
                case .identity(let identity)
                    where HIDPermissionPeerPolicy.accepts(expectedPID: application.processIdentifier,
                        expectedUID: getuid(), expectedPath: HIDInstalledHelperContract.helperExecutablePath,
                        peerPID: identity.pid, peerEUID: identity.uid, peerRUID: identity.realUID,
                        identity: identity):
                    operation.expectedPeer = identity
                    self.activatePermissionConnections(operation)
                case .absent where application.isTerminated ||
                    operation.terminatedPIDs.contains(application.processIdentifier):
                    self.permissionApplicationTerminated(operation)
                    return
                default:
                    self.closePermissionIPC(operation)
                    if operation.lifecycle.claimOutcome() {
                        self.deliverPermissionOutcomeKeepingGate(operation, status: .unknown,
                            message: "无法核验 LaunchServices 启动的按键辅助进程；不会发送输入监控请求。")
                    }
                    _ = application.terminate()
                }
                self.startPermissionProcessTimer(operation)
                if operation.ipcClosed || operation.lifecycle.timedOut || operation.lifecycle.cancelled {
                    self.closePermissionIPC(operation); _ = application.terminate()
                }
            }
        }
        let timeout: TimeInterval = request ? 120 : 10
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak operation] in
            guard let self, let operation, self.permissionOperation === operation else { return }
            if operation.lifecycle.markTimedOut() {
                self.closePermissionIPC(operation)
                _ = operation.application?.terminate()
                self.deliverPermissionOutcomeKeepingGate(operation, status: .unknown,
                    message: "输入监控检查或请求超时；已停止通信并请求结束本次按键辅助进程。在确认该进程退出前，不会重复检查或启用映射。")
            }
        }
    }

    private func permissionFinished(_ operation: PermissionOperation, fallback: String? = nil) {
        guard permissionOperation === operation, operation.lifecycle.mayComplete else { return }
        if operation.lifecycle.timedOut || operation.lifecycle.cancelled {
            finishPermission(operation, status: .unknown, message: "按键辅助进程已确认退出。", deliverCompletion: false)
            return
        }
        guard let response = operation.response else {
            let deliver = operation.lifecycle.claimOutcome()
            finishPermission(operation, status: .unknown,
                message: fallback ?? "已认证的按键辅助进程未返回完整输入监控状态。", deliverCompletion: deliver)
            return
        }
        let deliver = operation.lifecycle.claimOutcome()
        finishPermission(operation, status: response.status, message: response.message, deliverCompletion: deliver)
    }

    private func deliverPermissionOutcomeKeepingGate(_ operation: PermissionOperation,
                                                      status: HIDInputAccessStatus, message: String) {
        guard permissionOperation === operation, !operation.lifecycle.cancelled else { return }
        operation.completion(status, message)
    }

    private func finishPermission(_ operation: PermissionOperation, status: HIDInputAccessStatus, message: String,
                                  deliverCompletion: Bool = true) {
        guard permissionOperation === operation else { return }
        closePermissionIPC(operation)
        operation.processTimer?.invalidate(); operation.processTimer = nil
        if let observer = operation.terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer); operation.terminationObserver = nil
        }
        operation.application = nil; operation.expectedPeer = nil
        permissionOperation = nil; isCheckingInputAccess = false
        let currentGeneration = permissionGate.finish(operation.generation)
        if deliverCompletion && !operation.lifecycle.cancelled && currentGeneration {
            operation.completion(status, message)
        }
        if phase == .idle {
            let completions = stoppedHandlers; stoppedHandlers.removeAll()
            completions.forEach { $0() }
        }
    }

    private func isFixedPermissionApplication(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == HIDInstalledHelperContract.helperIdentifier &&
            application.bundleURL?.standardizedFileURL.path == HIDInstalledHelperContract.helperBundlePath
    }

    private func createPermissionListener(_ operation: PermissionOperation) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        operation.listener = fd
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(operation.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return false }
        // Record the just-bound inode before any later setup step can fail, so
        // finishPermission can safely remove this exact socket on every error
        // path instead of leaving a random private directory behind.
        var created = stat()
        guard lstat(operation.socketPath, &created) == 0,
              created.st_mode & S_IFMT == S_IFSOCK, created.st_uid == getuid(),
              created.st_nlink == 1 else { return false }
        operation.socketInode = created.st_ino
        guard chmod(operation.socketPath, 0o600) == 0 else { return false }
        var metadata = stat()
        guard lstat(operation.socketPath, &metadata) == 0,
              metadata.st_dev == created.st_dev, metadata.st_ino == created.st_ino,
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1 else { return false }
        guard listen(fd, 16) == 0 else { return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        operation.listenerSource = source
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self, weak operation] in
            guard let self, let operation, self.permissionOperation === operation,
                  !operation.ipcClosed else { return }
            for _ in 0..<16 {
                let accepted = accept(fd, nil, nil)
                if accepted < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                guard accepted >= 0 else { return }
                var noSignal: Int32 = 1
                guard fcntl(accepted, F_SETFL, O_NONBLOCK) == 0,
                      fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0,
                      setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                          socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    Darwin.close(accepted); continue
                }
                if operation.pendingConnections.count >= 16 {
                    Darwin.close(accepted); operation.rejectedConnections += 1
                } else { operation.pendingConnections.append(accepted) }
                self.activatePermissionConnections(operation)
                if operation.rejectedConnections > 64 {
                    self.failPermissionIPC(operation, "本地输入监控连接收到过多无效对端；不会发送权限请求。")
                    return
                }
            }
        }
        source.resume(); return true
    }

    private func activatePermissionConnections(_ operation: PermissionOperation) {
        guard permissionOperation === operation, let expected = operation.expectedPeer,
              !operation.ipcClosed else { return }
        let candidates = operation.pendingConnections; operation.pendingConnections.removeAll()
        for fd in candidates {
            guard operation.connection < 0,
                  HIDPermissionHelperPeerValidation.validate(fd: fd, expected: expected) else {
                Darwin.close(fd); operation.rejectedConnections += 1; continue
            }
            if operation.lifecycle.timedOut || operation.lifecycle.cancelled {
                Darwin.close(fd); _ = operation.application?.terminate(); continue
            }
            operation.connection = fd
            if let listener = operation.listenerSource { listener.cancel(); operation.listenerSource = nil }
            else if operation.listener >= 0 { Darwin.close(operation.listener) }
            operation.listener = -1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            operation.connectionSource = source
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self, weak operation] in
                guard let self, let operation, self.permissionOperation === operation else { return }
                self.readPermissionResponse(operation)
            }
            source.resume()
        }
    }

    private func readPermissionResponse(_ operation: PermissionOperation) {
        var bytes = [UInt8](repeating: 0, count: 2048)
        do {
            for _ in 0..<8 {
                let count = recv(operation.connection, &bytes, bytes.count, 0)
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                guard count > 0 else {
                    if operation.response == nil {
                        failPermissionIPC(operation, "已认证按键辅助进程未返回输入监控状态。")
                    }
                    return
                }
                let frames = try operation.lines.append(Data(bytes.prefix(count)))
                guard operation.response == nil, frames.count <= 1 else {
                    throw HIDClientDecoder.Invalid.frame
                }
                if frames.isEmpty { return }
                guard operation.lines.isEmpty else { throw HIDClientDecoder.Invalid.frame }
                if let line = frames.first {
                    if operation.challenge.isEmpty {
                        let message = try HIDPermissionChallenge.decode(line)
                        guard let expected = operation.expectedPeer,
                              HIDPermissionHelperPeerValidation.validate(fd: operation.connection,
                                  expected: expected) else {
                            throw HIDClientDecoder.Invalid.frame
                        }
                        operation.challenge = message.challenge
                        try sendPermissionRequest(operation)
                    } else {
                        // The helper may exit immediately after writing this
                        // result, so do not require a still-live process here.
                        // The same authenticated connection plus both nonces
                        // and operation semantics bind the queued result.
                        guard operation.requestSent else { throw HIDClientDecoder.Invalid.frame }
                        operation.response = try HIDPermissionResponse.decode(line,
                            nonce: operation.nonce, challenge: operation.challenge,
                            operation: operation.operation)
                        closePermissionConnection(operation)
                    }
                    return
                }
            }
        } catch { failPermissionIPC(operation, "输入监控结果校验失败；不会更新授权状态。") }
    }

    private func sendPermissionRequest(_ operation: PermissionOperation) throws {
        guard permissionOperation === operation, operation.connection >= 0,
              !operation.requestSent, !operation.challenge.isEmpty else {
            throw HIDClientDecoder.Invalid.frame
        }
        let data = try HIDPermissionRequest(nonce: operation.nonce,
            challenge: operation.challenge, operation: operation.operation).encodedLine()
        guard data.withUnsafeBytes({ Darwin.send(operation.connection, $0.baseAddress, $0.count, 0) == $0.count }),
              shutdown(operation.connection, SHUT_WR) == 0 else {
            throw HIDClientDecoder.Invalid.frame
        }
        operation.requestSent = true
    }

    private func failPermissionIPC(_ operation: PermissionOperation, _ message: String) {
        guard permissionOperation === operation else { return }
        closePermissionIPC(operation)
        if operation.lifecycle.claimOutcome() {
            deliverPermissionOutcomeKeepingGate(operation, status: .unknown, message: message)
        }
        _ = operation.application?.terminate()
    }

    private func closePermissionConnection(_ operation: PermissionOperation) {
        if operation.connection >= 0 { _ = shutdown(operation.connection, SHUT_RDWR) }
        if let source = operation.connectionSource { source.cancel(); operation.connectionSource = nil }
        else if operation.connection >= 0 { Darwin.close(operation.connection) }
        operation.connection = -1
    }

    private func closePermissionIPC(_ operation: PermissionOperation) {
        guard !operation.ipcClosed else { return }
        operation.ipcClosed = true
        closePermissionConnection(operation)
        for fd in operation.pendingConnections { Darwin.close(fd) }
        operation.pendingConnections.removeAll()
        if let source = operation.listenerSource { source.cancel(); operation.listenerSource = nil }
        else if operation.listener >= 0 { Darwin.close(operation.listener) }
        operation.listener = -1
        var socket = stat()
        if !operation.socketPath.isEmpty, lstat(operation.socketPath, &socket) == 0,
           socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == getuid(),
           socket.st_ino == operation.socketInode { _ = unlink(operation.socketPath) }
        var directory = stat()
        if !operation.directoryPath.isEmpty, lstat(operation.directoryPath, &directory) == 0,
           directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
           directory.st_ino == operation.directoryInode { _ = rmdir(operation.directoryPath) }
    }

    private func startPermissionProcessTimer(_ operation: PermissionOperation) {
        guard operation.processTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self, weak operation] timer in
            guard let self, let operation, self.permissionOperation === operation else { timer.invalidate(); return }
            if let expected = operation.expectedPeer {
                if HIDPermissionProcessObservationPolicy.confirmsExit(
                    HIDHelperPeer.read(expected.pid), expected: expected
                ) {
                    self.permissionApplicationTerminated(operation)
                }
            } else if operation.application?.isTerminated == true {
                self.permissionApplicationTerminated(operation)
            }
        }
        operation.processTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func permissionApplicationTerminated(_ operation: PermissionOperation) {
        guard permissionOperation === operation, !operation.lifecycle.helperExitConfirmed else { return }
        operation.lifecycle.recordApplicationTermination()
        // The helper writes its bounded response before exiting. A workspace
        // termination notification can race the socket read source, so drain
        // the already-authenticated stream before final cleanup.
        if operation.response == nil, operation.connection >= 0 {
            readPermissionResponse(operation)
            if operation.response == nil, operation.connection >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak operation] in
                    guard let self, let operation, self.permissionOperation === operation else { return }
                    self.readPermissionResponse(operation)
                    self.closePermissionIPC(operation)
                    self.permissionFinished(operation)
                }
                return
            }
        }
        closePermissionIPC(operation)
        permissionFinished(operation)
    }
    func stop(message: String = "已停止生成映射按键，正在释放遥控器。") {
        precondition(Thread.isMainThread)
        generation &+= 1
        cancelPermissionOperation()
        guard let current = session else { change(.idle, message); return }
        if current.closed { checkStopped(); return }
        if current.connection >= 0 { _ = send(["type": "stop"], to: current) }
        closeSession(current, message: message)
    }
    func checkStopped() {
        precondition(Thread.isMainThread)
        guard let current = session, current.closed else { return }
        if let peer = current.peer, !current.peerReleased {
            switch HIDHelperPeer.read(peer.pid) {
            case .absent: current.peerReleased = true
            case .identity(let now): current.peerReleased = now != peer
            case .unknown: break
            }
        }
        if (current.peer == nil || current.peerReleased), current.process == nil { complete(current); return }
        if ProcessInfo.processInfo.systemUptime >= current.closingDeadline {
            current.timer?.invalidate(); current.timer = nil
            change(.stopping, "本程序已停止输出，后台结束尚待确认。请取消尚未结束的系统授权，再点击“检查停止状态”；不会重复授权。")
        }
    }
    func whenStopped(_ completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        if !isRunning && !isCheckingInputAccess { completion() } else { stoppedHandlers.append(completion) }
    }

    private func cancelPermissionOperation() {
        guard let operation = permissionOperation, !operation.lifecycle.cancelled else { return }
        permissionGate.cancel(operation.generation); operation.lifecycle.markCancelled()
        closePermissionIPC(operation)
        guard operation.launchStarted else {
            finishPermission(operation, status: .unknown, message: "已取消输入监控检查或请求。", deliverCompletion: false)
            return
        }
        if let application = operation.application {
            _ = application.terminate()
            startPermissionProcessTimer(operation)
            if application.isTerminated { permissionApplicationTerminated(operation) }
        }
        // If LaunchServices has not returned the exact application yet, retain
        // the gate. The completion handler will terminate and track that exact
        // instance without ever sending the permission operation.
    }
    private func launch(target: HIDClientTarget, digest: String, allowed: Set<UInt16>) {
        do {
            var random = [UInt8](repeating: 0, count: 48)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw HIDClientDecoder.Invalid.frame }
            let folderToken = random.prefix(16).map { String(format: "%02x", $0) }.joined()
            let nonce = random.suffix(32).map { String(format: "%02x", $0) }.joined()
            let directory = "/private/var/tmp/OpenRemote-HID-\(getuid())-\(folderToken)"
            let current = Session(target: target, token: nonce, path: directory + "/session.sock", allowed: allowed)
            guard mkdir(directory, 0o700) == 0 else { throw HIDClientDecoder.Invalid.frame }
            session = current
            guard try createListener(current) else { throw HIDClientDecoder.Invalid.frame }
            let script = try HIDSessionScriptBuilder.appleScript(digest: digest, socket: current.path, token: nonce,
                pid: getpid(), uid: getuid(), target: target)
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            current.process = process; current.input = input; current.outputPipe = output; current.errorPipe = errors
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]; process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            for (pipe, isError) in [(output, false), (errors, true)] {
                pipe.fileHandleForReading.readabilityHandler = { [weak self, weak current] handle in
                    let part = (try? handle.read(upToCount: 4096)) ?? Data()
                    if part.isEmpty { handle.readabilityHandler = nil }
                    DispatchQueue.main.async {
                        guard let self, let current, self.session === current else { return }
                        if isError { current.errorCapture.append(part.prefix(max(0, 4096 - current.errorCapture.count))) }
                        else { current.outputCapture.append(part.prefix(max(0, 4096 - current.outputCapture.count))) }
                        if part.isEmpty {
                            if isError { current.errorEOF = true } else { current.outputEOF = true }
                        }
                        self.authorizationFinished(current)
                    }
                }
            }
            process.terminationHandler = { [weak self, weak current] child in
                DispatchQueue.main.async {
                    guard let self, let current, self.session === current else { return }
                    current.exitStatus = child.terminationStatus
                    self.authorizationFinished(current)
                }
            }
            try process.run()
            input.fileHandleForWriting.write(script); try? input.fileHandleForWriting.close()
            change(.authorizing, "等待管理员授权，仅接管所选遥控器；可取消启用。")
            let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self, weak current] _ in
                guard let self, let current, self.session === current else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.phase == .active {
                    guard now - current.lastReply < 3 else { self.fail(current, "按键辅助进程无响应，已停止映射并释放按键。"); return }
                    current.ping &+= 1
                    if !self.send(["type": "ping", "sequence": current.ping], to: current) { self.fail(current, "按键连接中断，已停止映射。") }
                } else if now >= current.deadline {
                    self.fail(current, "按键授权或连接超时，已取消本次接管；若系统授权窗口仍在，请选择取消。")
                }
            }
            current.timer = heartbeat; RunLoop.main.add(heartbeat, forMode: .common)
        } catch {
            if let current = session { current.process = nil; fail(current, "无法建立安全按键连接；未启用映射。") }
            else { change(.idle, "按键连接未建立。"); onFailure?("无法建立安全按键连接；未启用映射。") }
        }
    }
    private func createListener(_ current: Session) throws -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        current.listener = fd
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(current.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(current.path, 0o600) == 0 else { return false }
        var metadata = stat()
        guard lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid() else { return false }
        current.socketInode = metadata.st_ino
        guard listen(fd, 4) == 0 else { return false }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        current.listenerSource = source
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self, weak current] in
            guard let self, let current, self.session === current, !current.closed else { return }
            let accepted = accept(fd, nil, nil)
            guard accepted >= 0 else { return }
            var uid: uid_t = UInt32.max, gid: gid_t = UInt32.max
            var peer: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
            guard getpeereid(accepted, &uid, &gid) == 0, uid == 0,
                  getsockopt(accepted, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
                  size == MemoryLayout<pid_t>.size, peer > 1 else {
                Darwin.close(accepted); current.rejects += 1
                if current.rejects > 8 { self.fail(current, "本地按键连接身份不符；未接管遥控器。") }
                return
            }
            guard case .identity(let identity) = HIDHelperPeer.read(peer), identity.uid == 0 else {
                Darwin.close(accepted); self.fail(current, "无法核验按键辅助进程的本地身份；未启用映射。"); return
            }
            current.peer = identity
            current.listenerSource?.cancel(); current.listenerSource = nil; current.listener = -1
            current.connection = accepted
            guard fcntl(accepted, F_SETFL, O_NONBLOCK) == 0, fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0 else {
                self.fail(current, "无法配置安全按键连接。"); return
            }
            var noSignal: Int32 = 1
            guard setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                self.fail(current, "无法配置安全按键连接。"); return
            }
            let reader = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: .main)
            current.connectionSource = reader
            reader.setCancelHandler { Darwin.close(accepted) }
            reader.setEventHandler { [weak self, weak current] in
                guard let self, let current, self.session === current, !current.closed else { return }
                self.read(current)
            }
            reader.resume()
            if !self.send(["type": "hello", "version": 1, "token": current.token], to: current) { self.fail(current, "按键连接握手失败。") }
            current.deadline = ProcessInfo.processInfo.systemUptime + 10
        }
        source.resume(); return true
    }
    private func read(_ current: Session) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Bound one main-loop turn so a malicious stream cannot starve UI or
        // the independent heartbeat. No indefinite blocking or buffer growth.
        for _ in 0..<8 {
            let count = recv(current.connection, &bytes, bytes.count, 0)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else { fail(current, "按键辅助连接已关闭；映射已停止。"); return }
            do {
                for message in try current.decoder.receive(Data(bytes.prefix(count)), lastPing: current.ping) {
                    switch message {
                    case .ready:
                        guard phase == .authorizing else { throw HIDClientDecoder.Invalid.frame }
                        current.lastReply = ProcessInfo.processInfo.systemUptime
                        change(.active, "按键辅助进程已接管所选遥控器。")
                        onReady?(current.target)
                    case .keys(let usages): onKeys?(usages)
                    case .pong: current.lastReply = ProcessInfo.processInfo.systemUptime
                    case .failure(let code, let message):
                        guard !current.closed else { return }
                        closeSession(current, message: message)
                        if let onSessionFailure { onSessionFailure(code, message) }
                        else { onFailure?(message) }
                    case .stopped:
                        // The helper emits stopped only after IOHIDDeviceClose.
                        current.peerReleased = true
                        closeSession(current, message: "按键辅助会话已释放遥控器；映射已停止。")
                    }
                    if current.closed { return }
                }
            } catch { fail(current, "按键辅助数据校验失败；已停止映射，不转发异常按键。"); return }
        }
    }
    private func send(_ object: [String: Any], to current: Session) -> Bool {
        guard current.connection >= 0, !current.closed, var data = try? JSONSerialization.data(withJSONObject: object), data.count < 1024 else { return false }
        data.append(10)
        return data.withUnsafeBytes { Darwin.send(current.connection, $0.baseAddress, $0.count, 0) == $0.count }
    }
    private func fail(_ current: Session, _ message: String) {
        guard !current.closed else { return }
        closeSession(current, message: message); onFailure?(message)
    }
    private func authorizationFinished(_ current: Session) {
        guard session === current, let status = current.exitStatus, current.outputEOF, current.errorEOF else { return }
        current.process = nil
        if !current.closed {
            let cancelled = String(decoding: current.errorCapture, as: UTF8.self).contains("-128")
            let message = cancelled ? "已取消管理员授权；未启用映射。" : "按键辅助进程已退出（\(status)）；映射已停止。"
            if status == 0, let reported = HIDSessionAuthorizationEnvelope.failure(current.outputCapture) {
                closeSession(current, message: reported.message)
                if let onSessionFailure { onSessionFailure(reported.code, reported.message) }
                else { onFailure?(reported.message) }
                return
            }
            fail(current, message)
        } else { checkStopped() }
    }
    private func closeSession(_ current: Session, message: String) {
        guard !current.closed else { return }
        current.closed = true; current.timer?.invalidate(); current.timer = nil
        // shutdown immediately wakes the helper even before DispatchSource's
        // deferred close handler runs. Late authorization cannot reconnect.
        if current.connection >= 0 { _ = Darwin.shutdown(current.connection, SHUT_RDWR) }
        if let reader = current.connectionSource { reader.cancel(); current.connectionSource = nil }
        else if current.connection >= 0 { Darwin.close(current.connection) }
        if let listener = current.listenerSource { listener.cancel(); current.listenerSource = nil }
        else if current.listener >= 0 { Darwin.close(current.listener) }
        current.connection = -1; current.listener = -1
        var metadata = stat()
        if lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
           metadata.st_uid == getuid(), metadata.st_ino == current.socketInode { _ = unlink(current.path) }
        _ = rmdir(URL(fileURLWithPath: current.path).deletingLastPathComponent().path)
        change(.stopping, "本程序已停止输出，正在确认按键辅助进程结束。")
        if !current.notified { current.notified = true; onStopped?(message) }
        current.closingDeadline = ProcessInfo.processInfo.systemUptime + 5
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkStopped() }
        current.timer = timer; RunLoop.main.add(timer, forMode: .common)
        checkStopped()
        if current.process != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak current] in
                guard let self, let current, self.session === current, current.closed else { return }
                // Only our own osascript child is terminated. The root helper
                // exits on socket closure/heartbeat; no process name is killed.
                if let process = current.process, process.isRunning { process.terminate() }
            }
        }
    }
    private func complete(_ current: Session) {
        guard session === current else { return }
        current.timer?.invalidate(); current.timer = nil
        current.outputPipe?.fileHandleForReading.readabilityHandler = nil
        current.errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? current.input?.fileHandleForReading.close()
        try? current.outputPipe?.fileHandleForReading.close()
        try? current.errorPipe?.fileHandleForReading.close()
        session = nil; change(.idle, "按键辅助进程已结束。")
    }
    private func change(_ phase: Phase, _ message: String) {
        self.phase = phase; onChange?(phase, message)
        if phase == .idle {
            guard !isCheckingInputAccess else { return }
            let completions = stoppedHandlers; stoppedHandlers.removeAll()
            completions.forEach { $0() }
        }
    }
}
