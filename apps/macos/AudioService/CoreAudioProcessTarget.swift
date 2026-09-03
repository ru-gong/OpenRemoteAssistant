// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import Security

struct CoreAudioProcessIdentity: Codable, Equatable {
    static let executable = "/usr/sbin/coreaudiod"
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let realUID: UInt32
    let savedUID: UInt32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    func matchesSystemDaemon(uid expectedUID: UInt32) -> Bool {
        pid > 1 && parentPID == 1 && expectedUID > 0 && uid == expectedUID && realUID == expectedUID && savedUID == expectedUID
            && executablePath == Self.executable && startSeconds > 0 && startMicroseconds < 1_000_000
    }
    var diagnostic: AudioServiceDiagnostic {
        AudioServiceDiagnostic(targetPID: pid, targetUID: uid, targetStartSeconds: startSeconds, targetStartMicroseconds: startMicroseconds)
    }
}

/// This requirement accepts only the operating system's Apple-signed daemon,
/// not an ad-hoc product signature or a same-named user executable.
struct AudioServiceAppleSignature: AudioServiceSignatureChecking {
    func checkBundle(at path: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"com.apple.audio.coreaudiod\" and anchor apple" as CFString,
                SecCSFlags(), &requirement) == errSecSuccess, let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw AudioServiceFailure("系统 coreaudiod 的 Apple 签名或固定标识未通过校验。")
        }
    }
}

protocol CoreAudioSystemAssetChecking { func validate() throws }
struct CoreAudioSystemAssets: CoreAudioSystemAssetChecking {
    func validate() throws { try AudioServiceInstallation.production().checkCoreAudioSystemAssets() }
}
protocol CoreAudioIdentityReading {
    func systemAccountUID() throws -> UInt32
    func candidates() throws -> [CoreAudioProcessIdentity]
    func identity(pid: Int32) throws -> CoreAudioProcessIdentity
}
protocol CoreAudioTargetProviding {
    func verifiedIdentity() throws -> CoreAudioProcessIdentity
    func reread(_ previous: CoreAudioProcessIdentity) throws -> CoreAudioProcessIdentity
}

/// The same strictly read-only chain is exposed to the QA probe. It never
/// obtains a task port, runs a command, changes a service, or calls kill(2).
struct CoreAudioTargetValidator: CoreAudioTargetProviding {
    let assets: CoreAudioSystemAssetChecking
    let reader: CoreAudioIdentityReading
    init(assets: CoreAudioSystemAssetChecking = CoreAudioSystemAssets(), reader: CoreAudioIdentityReading = CoreAudioIdentityReader()) {
        self.assets = assets; self.reader = reader
    }
    func verifiedIdentity() throws -> CoreAudioProcessIdentity {
        try assets.validate()
        let uid = try reader.systemAccountUID()
        let candidates = try reader.candidates()
        guard candidates.count == 1, let identity = candidates.first, identity.matchesSystemDaemon(uid: uid) else {
            throw AudioServiceFailure("未找到唯一且身份完整的系统 coreaudiod；不按进程名称猜测或批量发送信号。")
        }
        return identity
    }
    func reread(_ previous: CoreAudioProcessIdentity) throws -> CoreAudioProcessIdentity {
        let uid = try reader.systemAccountUID()
        let current = try reader.identity(pid: previous.pid)
        guard previous.matchesSystemDaemon(uid: uid), current.matchesSystemDaemon(uid: uid), current == previous else {
            throw AudioServiceFailure("系统音频进程的 PID、路径、账户或启动时间已变化；本次未发送信号，请重新检查状态。")
        }
        return current
    }
}

/// kern.proc.pid is a read-only sysctl query here (newp nil, newlen zero).
/// Its ABI is checked against the SDK's complete structure; an unsupported
/// layout, vanished process, or invalid timestamp is rejected, not guessed.
struct CoreAudioKernelSnapshot {
    let info: kinfo_proc
    let status: Int32
    let byteCount: Int
    let errorNumber: Int32

    func identity(requestedPID: Int32, executable: String) throws -> CoreAudioProcessIdentity {
        guard status == 0, byteCount == MemoryLayout<kinfo_proc>.size else {
            throw AudioServiceFailure("无法完整读取系统音频进程身份（sysctl 返回 \(status)，errno \(errorNumber)，结构长度 \(byteCount)）。")
        }
        let started = info.kp_proc.p_un.__p_starttime
        guard requestedPID > 1, info.kp_proc.p_pid == requestedPID,
              started.tv_sec > 0, started.tv_usec >= 0, started.tv_usec < 1_000_000 else {
            throw AudioServiceFailure("系统音频进程身份的 PID 或启动时间无效；本次未发送信号。")
        }
        return CoreAudioProcessIdentity(pid: info.kp_proc.p_pid, parentPID: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid, realUID: info.kp_eproc.e_pcred.p_ruid,
            savedUID: info.kp_eproc.e_pcred.p_svuid, executablePath: executable,
            startSeconds: UInt64(started.tv_sec), startMicroseconds: UInt64(started.tv_usec))
    }
}

struct CoreAudioIdentityReader: CoreAudioIdentityReading {
    func systemAccountUID() throws -> UInt32 {
        guard let account = getpwnam("_coreaudiod"), account.pointee.pw_uid > 0 else {
            throw AudioServiceFailure("无法核实固定系统账户 _coreaudiod。")
        }
        return account.pointee.pw_uid
    }
    func candidates() throws -> [CoreAudioProcessIdentity] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0, estimated < 200_000 else { throw AudioServiceFailure("无法枚举系统音频进程。") }
        var ids = [pid_t](repeating: 0, count: Int(estimated) + 1024)
        let count = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < ids.count else { throw AudioServiceFailure("系统进程列表不完整，未选择信号目标。") }
        var result: [CoreAudioProcessIdentity] = []
        for pid in ids.prefix(Int(count)) where pid > 1 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno = 0
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                if String(cString: path) == CoreAudioProcessIdentity.executable { result.append(try identity(pid: pid)) }
            } else {
                let pathError = errno
                var name = [CChar](repeating: 0, count: 1024)
                errno = 0
                if proc_name(pid, &name, UInt32(name.count)) > 0 {
                    if String(cString: name) == "coreaudiod" {
                        throw AudioServiceFailure("发现无法核对完整路径的 coreaudiod；拒绝按名称发送信号。")
                    }
                } else if errno != ESRCH && pathError != ESRCH {
                    throw AudioServiceFailure("无法核对进程列表的完整性，未假定系统音频目标唯一。")
                }
            }
        }
        return result
    }
    func identity(pid: Int32) throws -> CoreAudioProcessIdentity {
        guard pid > 1 else { throw AudioServiceFailure("拒绝非正单进程 PID。") }
        let first = kernelSnapshot(pid)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw AudioServiceFailure("无法读取目标进程的完整可执行路径。") }
        let second = kernelSnapshot(pid)
        let executable = String(cString: path)
        let before = try first.identity(requestedPID: pid, executable: executable)
        guard before == (try second.identity(requestedPID: pid, executable: executable)) else {
            throw AudioServiceFailure("读取目标身份期间进程发生变化。")
        }
        return before
    }
    private func kernelSnapshot(_ pid: Int32) -> CoreAudioKernelSnapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        errno = 0
        let status = sysctl(&mib, 4, &info, &size, nil, 0)
        let readError = errno
        return CoreAudioKernelSnapshot(info: info, status: status, byteCount: size, errorNumber: readError)
    }
}

struct CoreAudioSignalResult { let returnCode: Int32; let errorNumber: Int32 }
protocol CoreAudioSignalSending { func send(to identity: CoreAudioProcessIdentity) -> CoreAudioSignalResult }

/// Exactly one syscall; positive PID only, fixed SIGTERM, no fallback command,
/// group signal, process search, task port, or service configuration operation.
struct CoreAudioPOSIXSignal: CoreAudioSignalSending {
    static let fixedSignal = SIGTERM
    func send(to identity: CoreAudioProcessIdentity) -> CoreAudioSignalResult {
        guard geteuid() == 0 else { return CoreAudioSignalResult(returnCode: -1, errorNumber: EPERM) }
        guard let account = getpwnam("_coreaudiod"), identity.matchesSystemDaemon(uid: account.pointee.pw_uid) else {
            return CoreAudioSignalResult(returnCode: -1, errorNumber: EINVAL)
        }
        errno = 0
        let status = Darwin.kill(identity.pid, Self.fixedSignal)
        let error = status == 0 ? 0 : errno
        return CoreAudioSignalResult(returnCode: status, errorNumber: error)
    }
}

struct FixedAudioServiceRequest: AudioServiceRequestSending {
    let target: CoreAudioTargetProviding
    let signal: CoreAudioSignalSending
    init(target: CoreAudioTargetProviding = CoreAudioTargetValidator(), signal: CoreAudioSignalSending = CoreAudioPOSIXSignal()) {
        self.target = target; self.signal = signal
    }
    func sendReloadRequest() throws -> AudioServiceDispatchOutcome {
        var diagnostic = AudioServiceDiagnostic()
        let selected: CoreAudioProcessIdentity
        do {
            selected = try target.verifiedIdentity()
            diagnostic = selected.diagnostic
            _ = try target.reread(selected)
        } catch {
            return .rejected(error.localizedDescription, diagnostic)
        }
        // POSIX kill does not atomically accept a birth time. The final read
        // greatly narrows, but cannot eliminate, the PID-reuse interval.
        let result = signal.send(to: selected)
        diagnostic.returnCode = result.returnCode
        diagnostic.errorNumber = result.errorNumber
        if result.returnCode == 0 {
            return .sent(diagnostic)
        }
        diagnostic.afterCheck = (try? target.reread(selected)) == selected ? "same_identity" : "changed_or_unavailable"
        if result.returnCode == -1 && [EPERM, ESRCH, EINVAL].contains(result.errorNumber) {
            return .rejected("系统返回 errno \(result.errorNumber)（\(String(cString: strerror(result.errorNumber)))）。未关闭系统保护或更改服务配置；可重新检查状态，必要时手动重启 Mac。", diagnostic)
        }
        return .unknown("信号接口返回非预期结果（返回值 \(result.returnCode)，errno \(result.errorNumber)）；请检查系统状态，不要自动重试。", diagnostic)
    }
}
