// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Darwin

struct UninstallSystemResult: Decodable {
    let success: Bool
    let message: String
    let restartRequired: Bool
    var recoveryPaths: [String]? = nil
    var displayedMessage: String {
        guard let paths = recoveryPaths, !paths.isEmpty else { return message }
        return message + "\n恢复位置：\n" + paths.joined(separator: "\n")
    }
}

struct UninstallAuthorizationEnvelope: Decodable {
    let helperExit: Int
    let cleanupSucceeded: Bool
    let result: UninstallSystemResult
}

enum UninstallOutputFormat { case preflight, authorizationEnvelope }

enum UninstallExecutionResult {
    case finished(UninstallSystemResult)
    case cancelled
    case failed(String)
    case unresolved(String)
}

/// Implementations deliver callbacks on the main queue. Tests can inject an
/// implementation that never launches a process or removes any data.
protocol UninstallExecuting {
    var isPreview: Bool { get }
    var isMainApplicationRunning: Bool { get }
    func preflight(completion: @escaping (UninstallExecutionResult) -> Void)
    func uninstall(completion: @escaping (UninstallExecutionResult) -> Void)
    func cleanUserData(removePersonalData: Bool, completion: @escaping (UserCleanupResult) -> Void)
}

enum UninstallPhase {
    case ready, checking, awaitingConfirmation, authorizing, cleaning
    case completed, partial, cancelled, failed, unresolved
    var isBusy: Bool {
        switch self {
        case .checking, .awaitingConfirmation, .authorizing, .cleaning: return true
        default: return false
        }
    }
}

/// The state machine separates preflight, consent, system removal and ordinary
/// user cleanup. A non-successful system result can never reach user cleanup.
final class UninstallSession {
    private let executor: UninstallExecuting
    private(set) var phase: UninstallPhase = .ready
    private(set) var message = "尚未开始卸载。个人设置默认保留。"
    private(set) var restartRequired = false
    private(set) var systemRemovalSucceeded = false
    private(set) var removePersonalData = false
    var onChange: (() -> Void)?
    var isPreview: Bool { executor.isPreview }

    init(executor: UninstallExecuting) {
        self.executor = executor
        if executor.isPreview { message = "界面预览：所有结果均为模拟，不调用工具、不授权、不删除文件。" }
    }

    func begin(removePersonalData: Bool) {
        guard !phase.isBusy, phase != .completed, phase != .unresolved else { return }
        if systemRemovalSucceeded {
            cleanUserData()
            return
        }
        guard !executor.isMainApplicationRunning else {
            update(.failed, "遥控器助手仍在运行。请先退出主程序，再点击重试；尚未请求管理员授权。")
            return
        }
        self.removePersonalData = removePersonalData
        update(.checking, isPreview ? "模拟检查安装状态…" : "正在只读检查安装状态，尚未请求管理员授权…")
        executor.preflight { [weak self] outcome in
            guard let self, self.phase == .checking else { return }
            switch outcome {
            case .finished(let result) where result.success:
                self.update(.awaitingConfirmation, result.displayedMessage)
            case .finished(let result):
                self.restartRequired = self.restartRequired || result.restartRequired
                self.update(result.restartRequired ? .partial : .failed, result.displayedMessage)
            case .cancelled: self.update(.cancelled, "检查已取消；本次未请求管理员授权。")
            case .failed(let message): self.update(.failed, message)
            case .unresolved(let message): self.update(.unresolved, message)
            }
        }
    }

    func confirmUninstall(_ confirmed: Bool) {
        guard phase == .awaitingConfirmation else { return }
        guard confirmed else {
            update(.cancelled, "本次未开始卸载，未请求管理员授权。")
            return
        }
        // Preflight is an observation, not a lasting authorization. The native
        // privileged helper repeats its ownership and process checks.
        guard !executor.isMainApplicationRunning else {
            update(.failed, "主程序又在运行。请先退出遥控器助手，再重新检查；未请求管理员授权。")
            return
        }
        update(.authorizing, isPreview ? "模拟系统卸载…" : "请在系统提示中授权或取消。卸载完成前请勿关闭此窗口。")
        executor.uninstall { [weak self] outcome in
            guard let self, self.phase == .authorizing else { return }
            switch outcome {
            case .finished(let result) where result.success:
                self.systemRemovalSucceeded = true
                self.restartRequired = result.restartRequired
                self.cleanUserData()
            case .finished(let result):
                self.restartRequired = self.restartRequired || result.restartRequired
                self.update(.partial, "系统卸载未全部完成。\n" + result.displayedMessage + "\n未清理个人设置；请根据上述信息修复安装后重试。")
            case .cancelled:
                self.update(.cancelled, "已取消系统管理员授权，本次未执行卸载。")
            case .failed(let message):
                self.update(.failed, message + "\n未确认系统卸载完成，未清理个人设置。")
            case .unresolved(let message):
                self.update(.unresolved, message + "\n未清理个人设置。请勿重复运行卸载；关闭界面不会取消后台工具。")
            }
        }
    }

    private func cleanUserData() {
        guard systemRemovalSucceeded else { return }
        update(.cleaning, isPreview ? "模拟当前用户数据清理…" : "系统组件已卸载，正在以当前用户权限处理设置和旧卸载临时副本…")
        executor.cleanUserData(removePersonalData: removePersonalData) { [weak self] result in
            guard let self, self.phase == .cleaning else { return }
            if result.success {
                self.update(.completed, "应用、遥控器按键服务和专用麦克风组件已卸载。\n" + result.message
                    + (self.restartRequired ? "\n请保存其他工作，稍后手动重新启动 Mac。" : ""))
            } else {
                self.update(.partial, "系统组件已卸载，但当前用户清理未全部完成。\n" + result.message
                    + "\n可重试清理；不会再次执行系统卸载。"
                    + (self.restartRequired ? "\n完成后请手动重新启动 Mac。" : ""))
            }
        }
    }

    private func update(_ phase: UninstallPhase, _ message: String) {
        self.phase = phase
        self.message = message
        onChange?()
    }
}

enum UninstallScriptBuilder {
    static let helperPath = "/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper"
    static let cancellationMarker = "OPENREMOTE_AUTH_CANCELLED"

    /// Only a validated build-time digest is interpolated. No path, checkbox,
    /// user name, helper output or other runtime input becomes shell code.
    static func shellScript(helperSHA256: String) throws -> String {
        let allowed = Set("0123456789abcdefABCDEF")
        guard helperSHA256.count == 64, helperSHA256.allSatisfy({ allowed.contains($0) }) else {
            throw ScriptError.invalidDigest
        }
        let digest = helperSHA256.lowercased()
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
                if ! /bin/rm -f "$stage/OpenRemoteUninstallHelper"; then cleanup_succeeded=false; fi
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
            /usr/bin/printf '{"helperExit":74,"cleanupSucceeded":%s,"result":{"success":false,"message":"卸载工具安全校验失败。未执行卸载；请使用完整安装包修复后重试。","restartRequired":false}}\\n' "$cleanup_succeeded"
            exit 0
        }
        stage=$(/usr/bin/mktemp -d /private/var/tmp/OpenRemote-uninstall-root.XXXXXXXX) || fail
        case "$stage" in /private/var/tmp/OpenRemote-uninstall-root.*) ;; *) stage=''; fail ;; esac
        [ ! -L '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper' ] && [ -f '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper' ] || fail
        /bin/cp -P '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper' "$stage/OpenRemoteUninstallHelper" || fail
        [ ! -L "$stage/OpenRemoteUninstallHelper" ] && [ -f "$stage/OpenRemoteUninstallHelper" ] || fail
        /usr/sbin/chown root:wheel "$stage/OpenRemoteUninstallHelper" || fail
        /bin/chmod 0500 "$stage/OpenRemoteUninstallHelper" || fail
        actual=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum -a 256 "$stage/OpenRemoteUninstallHelper") || fail
        [ "${actual%% *}" = '\(digest)' ] || fail
        helper_exit=0
        result_json=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C "$stage/OpenRemoteUninstallHelper" --uninstall) || helper_exit=$?
        if [ -z "$result_json" ] || [ "${#result_json}" -gt 60000 ]; then result_json=null; fi
        cleanup
        /usr/bin/printf '{"helperExit":%s,"cleanupSucceeded":%s,"result":%s}\\n' "$helper_exit" "$cleanup_succeeded" "$result_json"
        exit 0
        """
    }

    static func appleScript(helperSHA256: String) throws -> String {
        let shell = try shellScript(helperSHA256: helperSHA256)
        // Joining quoted lines avoids multiline AppleScript literal ambiguity.
        let expression = shell.components(separatedBy: "\n").map { line in
            "\"" + line.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
        var errorDescription: String? { "卸载界面缺少有效的工具校验信息。请使用完整安装包修复后重试。" }
    }
}

struct CapturedOutput {
    let data: Data
    let exceededLimit: Bool
}

/// A timeout and a late process completion can race. Only the first result is
/// delivered, and session phase checks provide a second boundary against a
/// delayed success advancing an unresolved operation to user-data cleanup.
final class UninstallCompletionGate {
    private let lock = NSLock()
    private var delivered = false
    func claimDelivery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}

/// Synchronous work is confined to background queues. Both output pipes are
/// drained concurrently, including overflow bytes, to avoid a full-pipe hang.
enum UninstallProcessRunner {
    static func run(executable: URL, arguments: [String], input: Data?,
                    format: UninstallOutputFormat,
                    completion: @escaping (UninstallExecutionResult) -> Void) {
        let gate = UninstallCompletionGate()
        let deadline = DispatchWorkItem {
            guard gate.claimDelivery() else { return }
            let message = format == .preflight
                ? "只读安装检查超过 30 秒仍未返回，状态待确认。尚未请求管理员授权；后台检查可能仍在运行，请勿重复启动。"
                : "系统授权或卸载调用超过 10 分钟仍未返回，结果待确认。后台工具可能仍在运行，界面不会终止它。"
            DispatchQueue.main.async { completion(.unresolved(message)) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (format == .preflight ? 30 : 600), execute: deadline)
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe(), errors = Pipe()
            let inputPipe = input == nil ? nil : Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
            do { try process.run() } catch {
                deadline.cancel()
                guard gate.claimDelivery() else { return }
                DispatchQueue.main.async {
                    completion(.failed("无法启动卸载检查或授权程序：" + error.localizedDescription))
                }
                return
            }
            try? inputPipe?.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            let group = DispatchGroup()
            let box = ProcessOutputBox()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.setOutput(drain(output.fileHandleForReading)); group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                box.setErrors(drain(errors.fileHandleForReading)); group.leave()
            }
            var inputFailed = false
            if let input, let inputPipe {
                do { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
                catch { inputFailed = true }
                try? inputPipe.fileHandleForWriting.close()
            }
            process.waitUntilExit()
            group.wait()
            let (stdout, stderr) = box.values()
            let result = interpret(stdout: stdout, stderr: stderr, status: process.terminationStatus,
                                   wasSignal: process.terminationReason == .uncaughtSignal, inputFailed: inputFailed,
                                   format: format)
            deadline.cancel()
            guard gate.claimDelivery() else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func drain(_ handle: FileHandle) -> CapturedOutput {
        defer { try? handle.close() }
        var data = Data()
        var exceeded = false
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty else { break }
                let remaining = max(0, 65_536 - data.count)
                if chunk.count > remaining { exceeded = true }
                data.append(chunk.prefix(remaining))
            } catch { return CapturedOutput(data: data, exceededLimit: true) }
        }
        return CapturedOutput(data: data, exceededLimit: exceeded)
    }

    static func interpret(stdout: CapturedOutput, stderr: CapturedOutput, status: Int32,
                          wasSignal: Bool, inputFailed: Bool,
                          format: UninstallOutputFormat) -> UninstallExecutionResult {
        let errorText = cleanMessage(String(data: stderr.data, encoding: .utf8) ?? "")
        if format == .authorizationEnvelope, !wasSignal, !inputFailed,
           !stdout.exceededLimit, !stderr.exceededLimit, stdout.data.isEmpty, status != 0,
           errorText.contains(UninstallScriptBuilder.cancellationMarker), errorText.contains("(-128)") {
            return .cancelled
        }
        guard !inputFailed, !stdout.exceededLimit, !stderr.exceededLimit, !wasSignal else {
            let message = "调用被中断或返回的数据不完整，无法确认最终结果。请勿将其视为已取消或已卸载。"
            return format == .authorizationEnvelope ? .unresolved(message) : .failed(message)
        }
        let result: UninstallSystemResult
        let operationExit: Int
        let stageCleaned: Bool
        switch format {
        case .preflight:
            guard let decoded = try? JSONDecoder().decode(UninstallSystemResult.self, from: stdout.data) else {
                return .failed("未收到有效的安装检查结果。" + (errorText.isEmpty ? "" : "\n" + errorText))
            }
            result = decoded; operationExit = Int(status); stageCleaned = true
        case .authorizationEnvelope:
            guard status == 0,
                  let envelope = try? JSONDecoder().decode(UninstallAuthorizationEnvelope.self, from: stdout.data),
                  (0...255).contains(envelope.helperExit) else {
                return .unresolved("未收到有效的系统卸载结果，最终状态待确认。" + (errorText.isEmpty ? "" : "\n" + errorText))
            }
            result = envelope.result; operationExit = envelope.helperExit; stageCleaned = envelope.cleanupSucceeded
        }
        guard
              !result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "未收到有效的卸载结果。" + (errorText.isEmpty ? "" : "\n" + errorText)
            return format == .authorizationEnvelope ? .unresolved(message) : .failed(message)
        }
        if (result.success && operationExit != 0) || !stageCleaned {
            return .finished(UninstallSystemResult(success: false,
                message: cleanMessage(result.displayedMessage)
                    + (operationExit != 0 ? "\n工具退出状态与结果不一致，仍需核查。" : "")
                    + (!stageCleaned ? "\n系统卸载工具的临时目录未清理，不能确认全部完成。" : "")
                    + (errorText.isEmpty ? "" : "\n" + errorText),
                restartRequired: result.restartRequired))
        }
        return .finished(UninstallSystemResult(success: result.success, message: cleanMessage(result.displayedMessage),
                                               restartRequired: result.restartRequired))
    }

    private static func cleanMessage(_ message: String) -> String {
        String(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }.prefix(4_096)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class ProcessOutputBox {
        private let lock = NSLock()
        private var output = CapturedOutput(data: Data(), exceededLimit: false)
        private var errors = CapturedOutput(data: Data(), exceededLimit: false)
        func setOutput(_ value: CapturedOutput) { lock.lock(); output = value; lock.unlock() }
        func setErrors(_ value: CapturedOutput) { lock.lock(); errors = value; lock.unlock() }
        func values() -> (CapturedOutput, CapturedOutput) {
            lock.lock(); defer { lock.unlock() }; return (output, errors)
        }
    }
}

final class LiveUninstallExecutor: UninstallExecuting {
    let isPreview = false
    private let cachedAuthorizationScript: Result<Data, Error>
    var isMainApplicationRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "org.rc001remote.assistant")
            .contains { !$0.isTerminated }
    }

    init(helperSHA256: String?) {
        // Cache before the helper moves/deletes our containing application.
        cachedAuthorizationScript = Result {
            Data(try UninstallScriptBuilder.appleScript(helperSHA256: helperSHA256 ?? "").utf8)
        }
    }

    func preflight(completion: @escaping (UninstallExecutionResult) -> Void) {
        guard getuid() != 0, geteuid() != 0 else { completion(.failed("卸载界面不能以 root 身份运行。")); return }
        if case .failure(let error) = cachedAuthorizationScript {
            completion(.failed(error.localizedDescription)); return
        }
        let url = URL(fileURLWithPath: UninstallScriptBuilder.helperPath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            completion(.failed("未找到完整安装中的卸载工具，部分组件可能已被移除。请使用完整安装包修复后重试。")); return
        }
        UninstallProcessRunner.run(executable: url, arguments: ["--preflight"], input: nil,
                                   format: .preflight, completion: completion)
    }

    func uninstall(completion: @escaping (UninstallExecutionResult) -> Void) {
        guard getuid() != 0, geteuid() != 0 else { completion(.failed("卸载界面不能以 root 身份运行。")); return }
        switch cachedAuthorizationScript {
        case .success(let script):
            UninstallProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                       arguments: ["-"], input: script, format: .authorizationEnvelope,
                                       completion: completion)
        case .failure(let error): completion(.failed(error.localizedDescription))
        }
    }

    func cleanUserData(removePersonalData: Bool, completion: @escaping (UserCleanupResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = UninstallUserData.clean(removePersonalData: removePersonalData)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class PreviewUninstallExecutor: UninstallExecuting {
    let isPreview = true
    let isMainApplicationRunning = false
    func preflight(completion: @escaping (UninstallExecutionResult) -> Void) {
        completion(.finished(.init(success: true, message: "模拟检查通过；未访问实际安装。", restartRequired: false)))
    }
    func uninstall(completion: @escaping (UninstallExecutionResult) -> Void) {
        completion(.finished(.init(success: true, message: "模拟系统卸载完成。", restartRequired: true)))
    }
    func cleanUserData(removePersonalData: Bool, completion: @escaping (UserCleanupResult) -> Void) {
        completion(UserCleanupResult(success: true,
            message: removePersonalData ? "模拟清理个人设置；实际文件未改动。" : "模拟保留个人设置；实际文件未改动。"))
    }
}

private final class UninstallerWindowController: NSWindowController, NSWindowDelegate {
    let session: UninstallSession
    private let personalData = NSButton(checkboxWithTitle: "同时删除按键方案、设备绑定、照片副本、校准和偏好（含默认输入恢复记录）", target: nil, action: nil)
    private let primary = NSButton(title: "开始卸载…", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = NSTextView()
    private var presentingConfirmation = false
    private var acknowledgedUnresolvedClose = false

    init(session: UninstallSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 690),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = session.isPreview ? "卸载遥控器助手 · 界面预览" : "卸载遥控器助手"
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildContents()
        session.onChange = { [weak self] in self?.render() }
        render()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContents() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        let title = label("卸载遥控器助手", size: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(label("应用、遥控器按键服务和专用麦克风由本机所有用户共享，卸载会影响所有用户。", size: 13))
        if session.isPreview {
            let preview = label("预览模式 · 只显示模拟状态，不授权、不删除、不重启。", size: 12, weight: .medium)
            preview.textColor = .systemOrange; stack.addArrangedSubview(preview)
        }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("将移除", size: 13, weight: .semibold))
        stack.addArrangedSubview(label("• 遥控器助手应用（含应用内按键服务副本）\n• 系统共享的“遥控器按键服务”\n• “遥控器麦克风”专用音频组件\n• 本程序的安装记录及旧卸载临时副本", size: 12))
        personalData.state = .off
        personalData.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(personalData)
        stack.addArrangedSubview(label("保留系统日志和其他音频设备；不会删除导入照片的原始文件。", size: 11, color: .secondaryLabelColor))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("开始前请结束会议或录音。系统将要求管理员授权；完成后需要你手动重启 Mac。不会自动重启，也不会更改默认音频设备。", size: 12))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        status.isEditable = false; status.isSelectable = true
        status.font = .systemFont(ofSize: 12); status.drawsBackground = false
        status.textContainerInset = NSSize(width: 7, height: 7)
        status.isVerticallyResizable = true; status.isHorizontallyResizable = false
        status.autoresizingMask = [.width]; status.textContainer?.widthTracksTextView = true
        scroll.documentView = status
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 98).isActive = true
        let actions = NSStackView()
        actions.orientation = .horizontal; actions.spacing = 10
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        actions.addArrangedSubview(progress)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.addArrangedSubview(spacer)
        closeButton.bezelStyle = .rounded; closeButton.target = self; closeButton.action = #selector(closeClicked)
        primary.bezelStyle = .rounded; primary.target = self; primary.action = #selector(startClicked)
        actions.addArrangedSubview(closeButton); actions.addArrangedSubview(primary)
        stack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in stack.arrangedSubviews where view is NSTextField || view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func label(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    private func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator; return line
    }

    private func render() {
        let busy = session.phase.isBusy
        personalData.isEnabled = !busy && !session.systemRemovalSucceeded && session.phase != .completed && session.phase != .unresolved
        primary.isEnabled = !busy && session.phase != .unresolved; closeButton.isEnabled = !busy
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        switch session.phase {
        case .completed: primary.title = "完成"
        case .partial where session.systemRemovalSucceeded: primary.title = "重试用户清理"
        case .failed, .partial, .cancelled: primary.title = "重新检查…"
        case .unresolved: primary.title = "结果待确认"
        default: primary.title = session.isPreview ? "模拟卸载…" : "开始卸载…"
        }
        status.string = (session.isPreview ? "【模拟】\n" : "") + session.message
        switch session.phase {
        case .failed, .partial, .unresolved: status.textColor = .systemRed
        case .completed: status.textColor = .systemGreen
        default: status.textColor = .labelColor
        }
        status.scrollToBeginningOfDocument(nil)
        if session.phase == .awaitingConfirmation, !presentingConfirmation {
            presentingConfirmation = true
            DispatchQueue.main.async { [weak self] in self?.confirmRemoval() }
        }
    }

    private func confirmRemoval() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = session.isPreview ? "模拟卸载确认" : "确定卸载遥控器助手？"
        alert.informativeText = "将移除所有用户共享的应用、遥控器按键服务和专用麦克风组件。"
            + (session.removePersonalData ? "同时删除当前用户的按键方案、设备绑定、照片副本、校准和偏好（含默认输入恢复记录）。" : "保留当前用户的按键方案、设备绑定、照片副本、校准和偏好（含默认输入恢复记录）。")
            + (session.isPreview ? "\n这只是预览，所有文件均保持不变。" : "\n下一步由 macOS 请求管理员授权。请先结束会议或录音，完成后手动重启。")
        alert.addButton(withTitle: session.isPreview ? "继续模拟" : "卸载并请求授权")
        alert.addButton(withTitle: "取消")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        presentingConfirmation = false
        session.confirmUninstall(accepted)
    }

    @objc private func startClicked() {
        if session.phase == .completed { closeClicked(); return }
        session.begin(removePersonalData: personalData.state == .on)
    }
    @objc private func closeClicked() { guard confirmClosing() else { return }; window?.close() }
    func confirmClosing() -> Bool {
        guard !session.phase.isBusy else { return false }
        guard session.phase == .unresolved, !acknowledgedUnresolvedClose else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭结果待确认的卸载界面？"
        alert.informativeText = "后台检查或卸载工具可能仍在进行。关闭这个窗口不会停止它，也不代表卸载已取消或已完成。请勿重复启动卸载。"
        alert.addButton(withTitle: "我已了解，关闭界面")
        alert.addButton(withTitle: "返回")
        acknowledgedUnresolvedClose = alert.runModal() == .alertFirstButtonReturn
        return acknowledgedUnresolvedClose
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClosing() }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

private final class UninstallerDelegate: NSObject, NSApplicationDelegate {
    private var controller: UninstallerWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
            || Bundle.main.object(forInfoDictionaryKey: "UIOnlyPreview") as? Bool == true
        let executor: UninstallExecuting = preview ? PreviewUninstallExecutor()
            : LiveUninstallExecutor(helperSHA256: Bundle.main.object(forInfoDictionaryKey: "OpenRemoteHelperSHA256") as? String)
        let controller = UninstallerWindowController(session: UninstallSession(executor: executor))
        self.controller = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.confirmClosing() == false ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !UNINSTALL_LOGIC_TESTS
@main
enum UninstallerApplication {
    static func main() {
        guard getuid() != 0, geteuid() != 0 else {
            FileHandle.standardError.write(Data("卸载界面不能以 root 身份运行。请以普通用户打开应用。\n".utf8))
            exit(77)
        }
        // A child may exit before consuming stdin. Treat the resulting write
        // failure as an unknown outcome instead of terminating this UI.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), applicationMenu = NSMenu()
        let item = NSMenuItem(); item.submenu = applicationMenu; menu.addItem(item)
        applicationMenu.addItem(withTitle: "退出卸载界面", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = menu
        let delegate = UninstallerDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
