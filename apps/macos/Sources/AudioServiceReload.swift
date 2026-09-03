// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

struct AudioReloadResponse: Decodable {
    let success: Bool
    let requestSent: Bool
    let message: String
    let phase: String
    var isAcceptedRequest: Bool { success && (requestSent || phase == "already_ready") }
}

enum AudioReloadOutcome {
    case response(AudioReloadResponse)
    case cancelled
    case failed(String)
    case unresolved(String)
}

enum AudioReloadBackgroundState: Equatable {
    case settled
    case active(String)
    case unavailable(String)
}

protocol AudioServiceReloadExecuting {
    var isPreview: Bool { get }
    func inspect(completion: @escaping (AudioDriverAvailability) -> Void)
    func stopOwnActivities(completion: @escaping () -> Void)
    func preflight(completion: @escaping (AudioReloadOutcome) -> Void)
    func requestReload(completion: @escaping (AudioReloadOutcome) -> Void)
    func checkBackgroundActivity(completion: @escaping (AudioReloadBackgroundState) -> Void)
}

final class AudioReloadScheduledTask {
    private let cancelWork: () -> Void
    init(cancel: @escaping () -> Void) { cancelWork = cancel }
    func cancel() { cancelWork() }
}

enum AudioReloadPhase {
    case idle, checking, stopping, preflight, rechecking, authorizing, verifying
    case ready, cancelled, failed, verificationTimedOut, unresolved, recovering, recovered
    var isBusy: Bool {
        [.checking, .stopping, .preflight, .rechecking, .authorizing, .verifying, .recovering].contains(self)
    }
    var blocksActions: Bool { isBusy || self == .unresolved }
    var blocksReload: Bool { blocksActions || self == .recovered }
}

/// Only a confirmed UI action calls begin(). Each async edge carries a token and
/// an expected phase; old completions cannot submit another request or mark a
/// timed-out request ready. No path restarts mappings or microphone capture.
final class AudioServiceReloadCoordinator {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> AudioReloadScheduledTask
    private let executor: AudioServiceReloadExecuting
    private let schedule: Scheduler
    private var token: UInt64 = 0
    private var deadline: AudioReloadScheduledTask?
    private var poll: AudioReloadScheduledTask?
    private(set) var phase: AudioReloadPhase = .idle
    private(set) var message = ""
    private(set) var didStopOwnActivities = false
    private(set) var requestWasSent = false
    var onChange: (() -> Void)?

    init(executor: AudioServiceReloadExecuting, schedule: @escaping Scheduler = AudioServiceReloadCoordinator.scheduleOnMain) {
        self.executor = executor; self.schedule = schedule
    }
    static func scheduleOnMain(after delay: TimeInterval, work: @escaping () -> Void) -> AudioReloadScheduledTask {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return AudioReloadScheduledTask { item.cancel() }
    }

    func begin() {
        guard !phase.blocksReload else { return }
        token &+= 1
        didStopOwnActivities = false; requestWasSent = false
        inspectBeforeRequest(token: token, afterStopping: false)
    }

    /// An explicit read-only recovery releases ordinary controls only after
    /// this invocation and any related privileged bootstrap have ended. Its
    /// uncertain reload is never reclassified as success or automatically retried.
    func checkRecovery() {
        guard phase == .unresolved else { return }
        token &+= 1
        let current = token
        set(.recovering, "正在只读核查本次授权、工具和后台任务是否已结束；不会发送重载请求。")
        arm(seconds: 5, token: current, expected: .recovering,
            message: "后台状态检查未及时返回，暂未解除相关操作保护。可稍后重新检查；不会再次发送请求。")
        executor.checkBackgroundActivity { [weak self] state in
            guard let self, self.matches(current, .recovering) else { return }
            switch state {
            case .settled:
                self.set(.recovered, "已确认本次后台任务结束，普通操作已恢复。此前重载结果仍未确认，本次不会再次发送请求；按键映射和麦克风不会自动恢复。音频组件状态由独立检查显示。")
            case .active(let detail), .unavailable(let detail):
                self.set(.unresolved, detail + "暂未解除相关操作保护；可稍后重新检查，不会再次发送请求。")
            }
        }
    }

    private func inspectBeforeRequest(token current: UInt64, afterStopping: Bool) {
        let expected: AudioReloadPhase = afterStopping ? .rechecking : .checking
        set(expected, "正在只读确认驱动文件与两个音频端点；尚未请求管理员授权。")
        arm(seconds: 5, token: current, expected: expected,
            message: "音频状态查询未及时返回，无法确认是否需要重载。尚未请求管理员授权；请勿重复操作。")
        executor.inspect { [weak self] availability in
            guard let self, self.matches(current, expected) else { return }
            switch availability {
            case .ready:
                self.set(.ready, "组件已生效，无需重新加载；未请求管理员授权。"
                    + (self.didStopOwnActivities ? "按键映射与麦克风接入保持关闭。" : "")
                    + "这不代表已验证实体遥控器收音。")
            case .installedUnloaded, .installedStale:
                if afterStopping { self.authorize(token: current) }
                else { self.stopOwnActivities(token: current) }
            default: self.set(.failed, availability.message + "未请求管理员授权。")
            }
        }
    }

    private func stopOwnActivities(token current: UInt64) {
        set(.stopping, "正在停止本程序的按键映射和遥控器语音，等待音频安全关闭…")
        arm(seconds: 5, token: current, expected: .stopping,
            message: "未能及时确认本程序音频已停止，已阻止管理员授权。请勿重复操作。")
        executor.stopOwnActivities { [weak self] in
            guard let self, self.matches(current, .stopping) else { return }
            self.didStopOwnActivities = true
            self.set(.preflight, "本程序功能已停止，正在只读检查音频服务工具…")
            self.executor.preflight { [weak self] outcome in
                guard let self, self.matches(current, .preflight) else { return }
                switch outcome {
                case .response(let result) where result.success && !result.requestSent:
                    self.inspectBeforeRequest(token: current, afterStopping: true)
                case .response(let result): self.set(.failed, result.message)
                case .cancelled: self.set(.cancelled, "已取消检查；未请求重载，个人安装状态没有被标记为失败。")
                case .failed(let message): self.set(.failed, message)
                case .unresolved(let message): self.set(.unresolved, message)
                }
            }
        }
    }

    private func authorize(token current: UInt64) {
        set(.authorizing, "请在系统提示中授权或取消。重载会中断整台电脑的播放、麦克风及会议音频。")
        executor.requestReload { [weak self] outcome in
            guard let self, self.matches(current, .authorizing) else { return }
            switch outcome {
            case .response(let result) where result.isAcceptedRequest:
                self.requestWasSent = result.requestSent
                self.set(.verifying, result.requestSent
                    ? "系统已收到重载请求，正在等待并核验两个专用音频端点（最多 25 秒）…"
                    : "系统检查发现端点可能已就绪，未发送重载请求；正在重新核验…")
                self.deadline = self.schedule(25) { [weak self] in
                    guard let self, self.matches(current, .verifying) else { return }
                    self.set(.verificationTimedOut, "25 秒内未确认两个专用音频端点就绪。"
                        + (self.requestWasSent ? "重载请求已发送，但不能据此认定组件已生效。" : "没有发送重载请求。")
                        + "可稍后重新检查，或保存工作后手动重启；不会自动再次重载，功能保持停止。")
                }
                self.pollEndpoints(token: current)
            case .response(let result): self.set(.failed,
                (result.phase == "request_rejected" ? "系统明确拒绝了本次请求，未执行重载。普通操作已恢复。" : "")
                    + result.message + "本程序功能保持停止，不会自动恢复。")
            case .cancelled: self.set(.cancelled, "已取消管理员授权，未发送重载请求。驱动安装状态保持独立显示；本程序功能保持停止。")
            case .failed(let message): self.set(.failed, message + "本程序功能保持停止。")
            case .unresolved(let message): self.set(.unresolved, message + "后台请求可能仍在进行；禁止重复重载，功能保持停止。")
            }
        }
    }

    private func pollEndpoints(token current: UInt64) {
        guard matches(current, .verifying) else { return }
        executor.inspect { [weak self] availability in
            guard let self, self.matches(current, .verifying) else { return }
            if availability == .ready {
                self.set(.ready, "组件已生效：两个专用音频端点已通过身份、在线状态和通道校验。"
                    + "按键映射与麦克风接入保持关闭；尚未验证实体遥控器收音。")
            } else {
                self.poll = self.schedule(1) { [weak self] in self?.pollEndpoints(token: current) }
            }
        }
    }
    private func matches(_ current: UInt64, _ expected: AudioReloadPhase) -> Bool { current == token && phase == expected }
    private func arm(seconds: TimeInterval, token current: UInt64, expected: AudioReloadPhase, message: String) {
        deadline = schedule(seconds) { [weak self] in
            guard let self, self.matches(current, expected) else { return }
            self.set(.unresolved, message)
        }
    }
    private func set(_ phase: AudioReloadPhase, _ message: String) {
        deadline?.cancel(); deadline = nil; poll?.cancel(); poll = nil
        self.phase = phase
        self.message = (executor.isPreview ? "【预览模拟】" : "") + message
        onChange?()
    }
}

enum AudioReloadScriptBuilder {
    static let helperPath = "/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper"
    static let cancellationMarker = "OPENREMOTE_AUDIO_AUTH_CANCELLED"
    static func shellScript(helperSHA256: String) throws -> String {
        let hex = Set("0123456789abcdefABCDEF")
        guard helperSHA256.count == 64, helperSHA256.allSatisfy({ hex.contains($0) }) else {
            throw ScriptError.invalidDigest
        }
        return """
        set -eu
        umask 077
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        LANG=C
        LC_ALL=C
        export PATH LANG LC_ALL
        stage=''
        cleanup_succeeded=true
        cleanup() {
            if [ -n "$stage" ]; then
                if ! /bin/rm -f "$stage/OpenRemoteAudioServiceHelper"; then cleanup_succeeded=false; fi
                if ! /bin/rmdir "$stage"; then cleanup_succeeded=false; fi
                stage=''
            fi
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        fail() {
            cleanup
            /usr/bin/printf '{"helperExit":74,"cleanupSucceeded":%s,"result":{"success":false,"requestSent":false,"message":"音频服务工具安全校验失败。未发出重载请求，请使用完整安装包修复。","phase":"bootstrap"}}\\n' "$cleanup_succeeded"
            exit 0
        }
        stage=$(/usr/bin/mktemp -d /private/var/tmp/OpenRemote-audio-service-root.XXXXXXXX) || fail
        case "$stage" in /private/var/tmp/OpenRemote-audio-service-root.*) ;; *) stage=''; fail ;; esac
        [ ! -L '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper' ] && [ -f '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper' ] || fail
        /bin/cp -P '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper' "$stage/OpenRemoteAudioServiceHelper" || fail
        [ ! -L "$stage/OpenRemoteAudioServiceHelper" ] && [ -f "$stage/OpenRemoteAudioServiceHelper" ] || fail
        /usr/sbin/chown root:wheel "$stage/OpenRemoteAudioServiceHelper" || fail
        /bin/chmod 0500 "$stage/OpenRemoteAudioServiceHelper" || fail
        actual=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum -a 256 "$stage/OpenRemoteAudioServiceHelper") || fail
        [ "${actual%% *}" = '\(helperSHA256.lowercased())' ] || fail
        helper_exit=0
        result_json=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C "$stage/OpenRemoteAudioServiceHelper" --reload) || helper_exit=$?
        if [ -z "$result_json" ] || [ "${#result_json}" -gt 60000 ]; then result_json=null; fi
        cleanup
        /usr/bin/printf '{"helperExit":%s,"cleanupSucceeded":%s,"result":%s}\\n' "$helper_exit" "$cleanup_succeeded" "$result_json"
        exit 0
        """
    }
    static func appleScript(helperSHA256: String) throws -> String {
        let shell = try shellScript(helperSHA256: helperSHA256)
        let expression = shell.components(separatedBy: "\n").map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " & linefeed & ")
        return """
        set commandText to \(expression)
        try
            return do shell script commandText with administrator privileges without altering line endings
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                error "\(cancellationMarker)" number -128
            end if
            error errorMessage number errorNumber
        end try
        """
    }
    enum ScriptError: LocalizedError {
        case invalidDigest
        var errorDescription: String? { "应用缺少有效的音频服务工具校验信息，请使用完整安装包修复；未发出重载请求。" }
    }
}

enum AudioReloadOutputFormat { case preflight, authorizationEnvelope }
struct AudioReloadCapturedOutput { let data: Data; let exceededLimit: Bool }
private struct AudioReloadEnvelope: Decodable { let helperExit: Int; let cleanupSucceeded: Bool; let result: AudioReloadResponse }

final class AudioReloadCompletionGate {
    private let lock = NSLock()
    private var delivered = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !delivered else { return false }; delivered = true; return true }
    var hasDelivered: Bool { lock.lock(); defer { lock.unlock() }; return delivered }
}

/// Tracks scheduled work as well as launched processes. Timeout only settles
/// the UI result; a pending launch or undrained process remains in flight.
final class AudioReloadExecutionTracker {
    private let lock = NSLock()
    private var pending = Set<UUID>()
    func begin() -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); pending.insert(id); return id }
    func finish(_ id: UUID) { lock.lock(); defer { lock.unlock() }; pending.remove(id) }
    var hasPendingWork: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
}

enum AudioReloadProcessRunner {
    static func interpret(stdout: AudioReloadCapturedOutput, stderr: AudioReloadCapturedOutput,
                          status: Int32, wasSignal: Bool = false, inputFailed: Bool = false,
                          format: AudioReloadOutputFormat) -> AudioReloadOutcome {
        let error = safeMessage(String(data: stderr.data, encoding: .utf8) ?? "")
        if format == .authorizationEnvelope, !wasSignal, !inputFailed, !stdout.exceededLimit, !stderr.exceededLimit,
           stdout.data.isEmpty, status != 0, error.contains(AudioReloadScriptBuilder.cancellationMarker), error.contains("(-128)") {
            return .cancelled
        }
        guard !wasSignal, !inputFailed, !stdout.exceededLimit, !stderr.exceededLimit else {
            return .unresolved("调用被中断或结果不完整，不能认定重载已取消或完成。")
        }
        let result: AudioReloadResponse
        switch format {
        case .preflight:
            guard let decoded = try? JSONDecoder().decode(AudioReloadResponse.self, from: stdout.data),
                  !decoded.requestSent, !(decoded.success && status != 0) else {
                return .failed("未收到有效的只读检查结果；未请求管理员授权。" + error)
            }
            result = decoded
        case .authorizationEnvelope:
            guard status == 0, let envelope = try? JSONDecoder().decode(AudioReloadEnvelope.self, from: stdout.data),
                  (0...255).contains(envelope.helperExit), envelope.cleanupSucceeded,
                  !(envelope.result.success && envelope.helperExit != 0) else {
                return .unresolved("未收到一致且完整的重载结果，或工具临时目录清理失败。" + error)
            }
            result = envelope.result
            if result.phase == "request_rejected" {
                guard !result.success, !result.requestSent, envelope.helperExit != 0 else {
                    return .unresolved("工具的明确拒绝结果与退出状态不一致；不能确认是否重载。")
                }
            }
            if !result.success && ["request_unknown", "already-attempted", "already_attempted", "request"].contains(result.phase) {
                return .unresolved(safeMessage(result.message) + "重载请求状态未知，禁止重复发送。")
            }
            if result.success && !result.requestSent && result.phase != "already_ready" {
                return .unresolved("工具未说明请求是否发送，不能认定组件已生效。")
            }
            if !result.success && result.requestSent { return .unresolved(safeMessage(result.message) + "请求可能已发送，但结果未确认。") }
        }
        guard !result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unresolved("工具没有返回可确认的状态说明。")
        }
        return .response(AudioReloadResponse(success: result.success, requestSent: result.requestSent,
            message: safeMessage(result.message), phase: result.phase))
    }

    static func run(executable: URL, arguments: [String], input: Data?, format: AudioReloadOutputFormat,
                    tracker: AudioReloadExecutionTracker,
                    completion: @escaping (AudioReloadOutcome) -> Void) {
        let invocation = tracker.begin()
        let gate = AudioReloadCompletionGate()
        let deadline = DispatchWorkItem {
            guard gate.claim() else { return }
            DispatchQueue.main.async {
                completion(.unresolved(format == .preflight
                    ? "只读检查超过 30 秒未返回；尚未授权，后台检查可能仍在运行。"
                    : "系统授权或重载调用超过 10 分钟未返回；后台请求可能仍在进行。"))
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (format == .preflight ? 30 : 600), execute: deadline)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { tracker.finish(invocation) }
            // If dispatch was delayed past the deadline, it must not launch
            // authorization later. The tracker covers the small run() race too.
            guard !gate.hasDelivered else { return }
            let process = Process(), output = Pipe(), errors = Pipe()
            let stdin = input == nil ? nil : Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardOutput = output; process.standardError = errors
            process.standardInput = stdin?.fileHandleForReading ?? FileHandle.nullDevice
            do { try process.run() } catch {
                deadline.cancel(); guard gate.claim() else { return }
                DispatchQueue.main.async { completion(.failed("无法启动音频服务工具：" + error.localizedDescription)) }; return
            }
            try? stdin?.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let group = DispatchGroup(), box = OutputBox()
            group.enter(); DispatchQueue.global(qos: .utility).async { box.store(drain(output.fileHandleForReading), isError: false); group.leave() }
            group.enter(); DispatchQueue.global(qos: .utility).async { box.store(drain(errors.fileHandleForReading), isError: true); group.leave() }
            var inputFailed = false
            if let input, let stdin {
                do { try stdin.fileHandleForWriting.write(contentsOf: input) } catch { inputFailed = true }
                try? stdin.fileHandleForWriting.close()
            }
            process.waitUntilExit(); group.wait()
            let pair = box.read()
            let result = interpret(stdout: pair.0, stderr: pair.1, status: process.terminationStatus,
                wasSignal: process.terminationReason == .uncaughtSignal, inputFailed: inputFailed, format: format)
            deadline.cancel(); guard gate.claim() else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private static func drain(_ handle: FileHandle) -> AudioReloadCapturedOutput {
        defer { try? handle.close() }
        var data = Data(), exceeded = false
        while true {
            do {
                guard let part = try handle.read(upToCount: 8192), !part.isEmpty else { break }
                let capacity = max(0, 65_536 - data.count)
                if part.count > capacity { exceeded = true }
                data.append(part.prefix(capacity))
            } catch { return .init(data: data, exceededLimit: true) }
        }
        return .init(data: data, exceededLimit: exceeded)
    }
    private static func safeMessage(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }.prefix(4096))
    }
    private final class OutputBox {
        private let lock = NSLock()
        private var output = AudioReloadCapturedOutput(data: Data(), exceededLimit: false)
        private var error = AudioReloadCapturedOutput(data: Data(), exceededLimit: false)
        func store(_ value: AudioReloadCapturedOutput, isError: Bool) { lock.lock(); defer { lock.unlock() }; if isError { error = value } else { output = value } }
        func read() -> (AudioReloadCapturedOutput, AudioReloadCapturedOutput) { lock.lock(); defer { lock.unlock() }; return (output, error) }
    }
}

struct AudioReloadBackgroundProcess {
    let name: String
    let potentialBootstrap: Bool
    let arguments: String?
}

/// Read-only fallback for a privileged descendant which outlived osascript.
/// Only fixed helper names, root shell bootstrap markers and the old fixed
/// coreaudiod command are relevant. Unrelated osascript jobs are not blockers;
/// the exact invocation belonging to this app is tracked separately above.
enum AudioReloadBackgroundProbe {
    static func classify(_ processes: [AudioReloadBackgroundProcess], stagingPresent: Bool = false,
                         stagingQuerySucceeded: Bool = true) -> AudioReloadBackgroundState {
        guard stagingQuerySucceeded else { return .unavailable("无法核查音频工具的临时目录状态。") }
        if stagingPresent { return .active("音频工具的管理员临时目录仍存在，尚不能确认后台任务与清理均已结束。") }
        for process in processes {
            if process.name.hasPrefix("OpenRemoteAudio") {
                return .active("遥控器助手的音频后台工具仍在运行。")
            }
            guard process.potentialBootstrap else { continue }
            guard let arguments = process.arguments else {
                return .unavailable("发现无法确认身份的后台命令，不能排除本次授权仍有任务在运行。")
            }
            if arguments.contains("OpenRemote-audio-service-root.") || arguments.contains(AudioReloadScriptBuilder.helperPath)
                || (process.name == "launchctl" && arguments.contains("com.apple.audio.coreaudiod")) {
                return .active("本次音频服务命令或管理员后台任务仍在运行。")
            }
        }
        return .settled
    }

    static func read() -> AudioReloadBackgroundState {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0, estimate < 200_000 else { return .unavailable("无法读取后台进程状态。") }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 1024)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { return .unavailable("后台进程查询不完整。") }
        var records: [AudioReloadBackgroundProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != getpid() {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno = 0
            let pathCount = proc_pidpath(pid, &path, UInt32(path.count))
            let pathError = errno
            let name: String
            if pathCount > 0 { name = URL(fileURLWithPath: String(cString: path)).lastPathComponent }
            else {
                var shortName = [CChar](repeating: 0, count: 1024)
                errno = 0
                if proc_name(pid, &shortName, UInt32(shortName.count)) > 0 { name = String(cString: shortName) }
                else if errno == ESRCH || pathError == ESRCH { continue }
                else { return .unavailable("无法核查某个后台进程，暂未假定授权已结束。") }
            }
            if name.hasPrefix("OpenRemoteAudio") {
                records.append(.init(name: name, potentialBootstrap: false, arguments: nil)); continue
            }
            if name == "launchctl" {
                records.append(.init(name: name, potentialBootstrap: true, arguments: arguments(pid))); continue
            }
            if ["sh", "bash", "zsh"].contains(name) {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                errno = 0
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                    if info.pbi_uid == 0 { records.append(.init(name: name, potentialBootstrap: true, arguments: arguments(pid))) }
                } else if errno != ESRCH { return .unavailable("无法确认后台 shell 的身份，暂未解除保护。") }
            }
        }
        // Only enumerate matching names in the fixed staging parent; never
        // enter, read or remove their contents during recovery.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/tmp") else {
            return classify(records, stagingQuerySucceeded: false)
        }
        return classify(records, stagingPresent: entries.contains { $0.hasPrefix("OpenRemote-audio-service-root.") })
    }

    private static func arguments(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 262_144 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0, size <= bytes.count, size > 4 else { return nil }
        bytes = Array(bytes.prefix(size))
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count < 1024 else { return nil }
        var cursor = 4
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count else { return nil }
            result.append(String(decoding: bytes[start..<cursor], as: UTF8.self)); cursor += 1
        }
        // Ignore the environment tail entirely and never expose arguments in UI.
        return result.joined(separator: " ")
    }
}

final class LiveAudioServiceReloadExecutor: AudioServiceReloadExecuting {
    let isPreview = false
    private let authorizationScript: Result<Data, Error>
    private let expectedHelperDigest: String
    private let inspectWork: (@escaping (AudioDriverAvailability) -> Void) -> Void
    private let stopWork: (@escaping () -> Void) -> Void
    private let tracker = AudioReloadExecutionTracker()
    init(helperSHA256: String?, inspect: @escaping (@escaping (AudioDriverAvailability) -> Void) -> Void,
         stopOwnActivities: @escaping (@escaping () -> Void) -> Void) {
        authorizationScript = Result { Data(try AudioReloadScriptBuilder.appleScript(helperSHA256: helperSHA256 ?? "").utf8) }
        expectedHelperDigest = (helperSHA256 ?? "").lowercased()
        inspectWork = inspect; stopWork = stopOwnActivities
    }
    func inspect(completion: @escaping (AudioDriverAvailability) -> Void) { inspectWork(completion) }
    func stopOwnActivities(completion: @escaping () -> Void) {
        let operation = tracker.begin()
        stopWork { [tracker] in tracker.finish(operation); completion() }
    }
    func checkBackgroundActivity(completion: @escaping (AudioReloadBackgroundState) -> Void) {
        let tracker = tracker
        DispatchQueue.global(qos: .utility).async {
            let state = tracker.hasPendingWork
                ? AudioReloadBackgroundState.active("本次授权、工具调用或音频关闭任务仍未结束。")
                : AudioReloadBackgroundProbe.read()
            DispatchQueue.main.async {
                completion(tracker.hasPendingWork ? .active("本次后台任务仍在进行。") : state)
            }
        }
    }
    func preflight(completion: @escaping (AudioReloadOutcome) -> Void) {
        guard getuid() != 0, geteuid() == getuid() else { completion(.failed("请以普通用户运行遥控器助手。")); return }
        if case .failure(let error) = authorizationScript { completion(.failed(error.localizedDescription)); return }
        let file = URL(fileURLWithPath: AudioReloadScriptBuilder.helperPath)
        let expected = expectedHelperDigest
        let gate = AudioReloadCompletionGate()
        let validation = tracker.begin()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            guard gate.claim() else { return }
            DispatchQueue.main.async { completion(.unresolved("只读工具校验未及时结束；尚未请求管理员授权。请勿重复操作。")) }
        }
        DispatchQueue.global(qos: .utility).async {
            let error = AudioReloadHelperValidation.validationError(at: file, expectedDigest: expected, expectedOwner: 0)
            // A late file read cannot start a process after its deadline.
            guard gate.claim() else { self.tracker.finish(validation); return }
            DispatchQueue.main.async {
                defer { self.tracker.finish(validation) }
                if let error { completion(.failed(error)); return }
                AudioReloadProcessRunner.run(executable: file, arguments: ["--preflight"], input: nil, format: .preflight,
                    tracker: self.tracker, completion: completion)
            }
        }
    }
    func requestReload(completion: @escaping (AudioReloadOutcome) -> Void) {
        guard getuid() != 0, geteuid() == getuid() else { completion(.failed("请以普通用户运行遥控器助手。")); return }
        switch authorizationScript {
        case .failure(let error): completion(.failed(error.localizedDescription))
        case .success(let input):
            AudioReloadProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-"],
                input: input, format: .authorizationEnvelope, tracker: tracker, completion: completion)
        }
    }
}

/// Ordinary-user preflight checks the fixed executable before running it. The
/// administrator bootstrap separately copies and pins its root-private image;
/// this read is not a replacement for that authorization boundary. Alternate
/// paths and owners are only used by isolated synthetic-file tests.
enum AudioReloadHelperValidation {
    static let maximumBytes = 16 * 1024 * 1024
    static func validationError(at url: URL, expectedDigest: String, expectedOwner: uid_t) -> String? {
        let failure = "音频服务工具文件、权限或校验值不符，请先用完整安装包更新或修复。未执行工具、未请求管理员授权。"
        guard expectedDigest.count == 64,
              expectedDigest.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return failure }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return failure }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == expectedOwner, before.st_mode & 0o022 == 0,
              before.st_mode & 0o100 != 0, before.st_size > 0,
              before.st_size <= maximumBytes else { return failure }
        let started = DispatchTime.now().uptimeNanoseconds
        var hasher = SHA256(), count = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while count <= maximumBytes {
            guard DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000 else { return failure }
            let received = Darwin.read(fd, &buffer, buffer.count)
            if received < 0 { if errno == EINTR { continue }; return failure }
            if received == 0 { break }
            count += received
            guard count <= maximumBytes else { return failure }
            hasher.update(data: Data(buffer.prefix(received)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, count == before.st_size, after.st_size == before.st_size,
              after.st_uid == before.st_uid, after.st_mode == before.st_mode,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { return failure }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == expectedDigest.lowercased() ? nil : failure
    }
}

enum AudioReloadPreviewScenario: String {
    case success, rejected
    case unknownRecoverable = "unknown-recoverable"
    case unknownBusy = "unknown-busy"
    static func selected(arguments: [String], plistValue: String?) -> AudioReloadPreviewScenario {
        let option = "--audio-reload-preview-scenario"
        let value: String?
        if let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) { value = arguments[index + 1] }
        else { value = plistValue }
        return value.flatMap(Self.init(rawValue:)) ?? .success
    }
}

final class PreviewAudioServiceReloadExecutor: AudioServiceReloadExecuting {
    let isPreview = true
    var availability: AudioDriverAvailability
    let scenario: AudioReloadPreviewScenario
    init(availability: AudioDriverAvailability, scenario: AudioReloadPreviewScenario = .success) {
        self.availability = availability; self.scenario = scenario
    }
    func inspect(completion: @escaping (AudioDriverAvailability) -> Void) { completion(availability) }
    func stopOwnActivities(completion: @escaping () -> Void) { completion() }
    func preflight(completion: @escaping (AudioReloadOutcome) -> Void) {
        completion(.response(.init(success: true, requestSent: false, message: "模拟检查通过", phase: "preflight")))
    }
    func requestReload(completion: @escaping (AudioReloadOutcome) -> Void) {
        switch scenario {
        case .success:
            availability = .ready
            completion(.response(.init(success: true, requestSent: true, message: "模拟请求已发送，未触碰系统服务", phase: "requested")))
        case .rejected:
            completion(.response(.init(success: false, requestSent: false, message: "模拟系统拒绝，未触碰系统服务。", phase: "request_rejected")))
        case .unknownRecoverable, .unknownBusy:
            completion(.unresolved("模拟旧版请求结果未知，未触碰系统服务。"))
        }
    }
    func checkBackgroundActivity(completion: @escaping (AudioReloadBackgroundState) -> Void) {
        completion(scenario == .unknownBusy ? .active("模拟后台授权任务仍未结束。") : .settled)
    }
}
