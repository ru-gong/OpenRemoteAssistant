// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure injected-state and text-protocol tests. This executable never creates a
/// Process, opens a window, asks for authorization or calls real user cleanup.
@main
enum UninstallerLogicTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        let digest = String(repeating: "a", count: 64)
        let shell = try UninstallScriptBuilder.shellScript(helperSHA256: digest)
        let appleScript = try UninstallScriptBuilder.appleScript(helperSHA256: digest)
        check(shell.contains("/private/var/tmp/OpenRemote-uninstall-root.XXXXXXXX"), "fixed root staging parent")
        check(shell.contains("/bin/cp -P '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper'"), "fixed non-dereferencing copy")
        check(shell.contains("[ ! -L \"$stage/OpenRemoteUninstallHelper\" ]"), "reject staged symlink")
        check(shell.contains("[ -f \"$stage/OpenRemoteUninstallHelper\" ]"), "require staged regular file")
        check(shell.contains("/usr/sbin/chown root:wheel") && shell.contains("/bin/chmod 0500"), "privileged stage executable ownership")
        check(shell.contains("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum"), "hash environment cleared")
        check(shell.contains("[ \"${actual%% *}\" = '" + digest + "' ]"), "expected digest compared before execution")
        check(shell.contains("helper_exit=$?") && shell.contains("cleanupSucceeded"), "exit status and cleanup preserved in envelope")
        check(shell.contains("trap cleanup EXIT") && shell.contains("trap 'exit 143' TERM"), "cleanup and signal exit are explicit")
        check(!shell.contains("rm -rf") && !shell.contains(".pkg"), "no recursive shell removal or installer package")
        check(appleScript.contains("with administrator privileges without altering line endings"), "uses system authorization")
        check(appleScript.contains("OPENREMOTE_AUTH_CANCELLED") && appleScript.contains("errorNumber is -128"), "cancellation has exact marker and error number")
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                        String(repeating: "g", count: 64), String(repeating: "ａ", count: 64), "'; exit 0; #"] {
            check((try? UninstallScriptBuilder.shellScript(helperSHA256: invalid)) == nil, "invalid digest rejected")
        }
        let upperCaseScript = try UninstallScriptBuilder.shellScript(helperSHA256: digest.uppercased())
        check(upperCaseScript == shell, "hex digest normalized")

        func interpret(_ output: String, exit: Int32 = 0, error: String = "", signal: Bool = false,
                       overflow: Bool = false, inputFailed: Bool = false,
                       format: UninstallOutputFormat = .authorizationEnvelope) -> UninstallExecutionResult {
            UninstallProcessRunner.interpret(stdout: CapturedOutput(data: Data(output.utf8), exceededLimit: overflow),
                stderr: CapturedOutput(data: Data(error.utf8), exceededLimit: false), status: exit,
                wasSignal: signal, inputFailed: inputFailed, format: format)
        }
        func isSuccessful(_ outcome: UninstallExecutionResult) -> Bool {
            if case .finished(let result) = outcome { return result.success }
            return false
        }
        func isCancelled(_ outcome: UninstallExecutionResult) -> Bool {
            if case .cancelled = outcome { return true }; return false
        }
        func isUnresolved(_ outcome: UninstallExecutionResult) -> Bool {
            if case .unresolved = outcome { return true }; return false
        }
        let success = "{\"success\":true,\"message\":\"removed\",\"restartRequired\":true}"
        let failure = "{\"success\":false,\"message\":\"partial removal\",\"restartRequired\":true,\"recoveryPaths\":[\"/Library/Audio/Plug-Ins/HAL/.recovery-fixture\"]}"
        func envelope(_ result: String, helperExit: Int = 0, cleanup: Bool = true) -> String {
            "{\"helperExit\":\(helperExit),\"cleanupSucceeded\":\(cleanup),\"result\":\(result)}"
        }
        check(isSuccessful(interpret(envelope(success))), "three-part authorization success accepted")
        check(!isSuccessful(interpret(envelope(success, helperExit: 1))), "nonzero helper exit cannot report success")
        check(!isSuccessful(interpret(envelope(success, cleanup: false))), "cleanup failure cannot report success")
        check(!isSuccessful(interpret(envelope(failure))), "zero exit does not override helper failure")
        let preservedFailure = interpret(envelope(failure, helperExit: 74))
        if case .finished(let result) = preservedFailure {
            check(!result.success && result.restartRequired, "partial helper status preserved")
            check(result.message.contains("partial removal") && result.message.contains(".recovery-fixture"), "failure and recovery location preserved")
        } else { fatalError("failure envelope was not decoded") }
        check(!isSuccessful(interpret(envelope(success), exit: 1)), "osascript nonzero status cannot report success")
        check(!isSuccessful(interpret(envelope(success, helperExit: -1))), "invalid negative helper exit rejected")
        check(!isSuccessful(interpret(envelope(success, helperExit: 256))), "invalid oversized helper exit rejected")
        check(!isSuccessful(interpret(envelope("null"))), "missing helper JSON is unknown, not success")
        check(!isSuccessful(interpret("")), "normal exit with no JSON is not success")
        check(!isSuccessful(interpret("log\n" + envelope(success))), "noise before JSON rejected")
        check(!isSuccessful(interpret(envelope(success) + envelope(success))), "multiple JSON objects rejected")
        check(!isSuccessful(interpret(envelope(success), overflow: true)), "oversized output rejected")
        check(!isSuccessful(interpret(envelope(success), inputFailed: true)), "stdin failure rejected")
        check(isSuccessful(interpret(success, format: .preflight)), "preflight accepts raw JSON")
        check(!isSuccessful(interpret(success, exit: 1, format: .preflight)), "preflight exit mismatch rejected")
        let cancelled = "execution error: OPENREMOTE_AUTH_CANCELLED (-128)"
        check(isCancelled(interpret("", exit: 1, error: cancelled)), "only marked authorization cancellation accepted")
        check(!isCancelled(interpret("", exit: 1, error: "User cancelled (-128)")), "unmarked error does not imply cancellation")
        check(!isCancelled(interpret("", exit: 1, error: cancelled, signal: true)), "signal is not cancellation")
        check(!isCancelled(interpret("", exit: 1, error: cancelled, inputFailed: true)), "incomplete script is not cancellation")
        check(!isCancelled(interpret("", exit: 1, error: cancelled, overflow: true)), "truncated streams are not cancellation")
        check(!isCancelled(interpret(envelope(success), exit: 1, error: cancelled)), "output plus cancellation marker is an unknown result")
        check(!isCancelled(interpret("", exit: 1, error: cancelled, format: .preflight)), "preflight cannot impersonate authorization cancellation")
        check(isUnresolved(interpret("")), "missing authorization result requires confirmation, not retry")
        check(isUnresolved(interpret(envelope(success), signal: true)), "interrupted authorization remains unresolved")
        check(isUnresolved(interpret(envelope("null"))), "malformed helper result remains unresolved")
        let gate = UninstallCompletionGate()
        check(gate.claimDelivery() && !gate.claimDelivery() && !gate.claimDelivery(), "only one deadline/process result can be delivered")

        let fixture = FakeUninstallExecutor()
        let session = UninstallSession(executor: fixture)
        check(session.phase == .ready && fixture.calls.isEmpty, "construction performs no operation")
        session.begin(removePersonalData: false)
        check(session.phase == .awaitingConfirmation && fixture.calls == ["preflight"], "preflight does not authorize or delete")
        session.confirmUninstall(false)
        check(session.phase == .cancelled && fixture.calls == ["preflight"], "cancelled confirmation never starts uninstall")
        fixture.system = .cancelled
        session.begin(removePersonalData: true); session.confirmUninstall(true)
        check(session.phase == .cancelled && !fixture.calls.contains("cleanup"), "authorization cancellation never cleans user data")
        fixture.system = .finished(.init(success: false, message: "partially removed", restartRequired: true))
        session.begin(removePersonalData: true); session.confirmUninstall(true)
        check(session.phase == .partial && session.restartRequired && !fixture.calls.contains("cleanup"), "system failure preserves data and restart warning")

        let cleanupFixture = FakeUninstallExecutor()
        cleanupFixture.cleanupResult = .init(success: false, message: "fixture cleanup failed")
        let cleanupSession = UninstallSession(executor: cleanupFixture)
        cleanupSession.begin(removePersonalData: true); cleanupSession.confirmUninstall(true)
        check(cleanupSession.systemRemovalSucceeded && cleanupSession.phase == .partial, "cleanup failure is partial completion")
        check(cleanupFixture.cleanupChoices == [true], "explicit data choice reaches cleanup")
        cleanupFixture.cleanupResult = .init(success: true, message: "fixture cleaned")
        cleanupSession.begin(removePersonalData: false)
        check(cleanupSession.phase == .completed && cleanupFixture.calls.filter { $0 == "uninstall" }.count == 1, "retry cleanup never repeats system uninstall")
        check(cleanupFixture.cleanupChoices == [true, true], "retry keeps confirmed original personal-data choice")

        let runningFixture = FakeUninstallExecutor()
        runningFixture.isMainApplicationRunning = true
        let runningSession = UninstallSession(executor: runningFixture)
        runningSession.begin(removePersonalData: false)
        check(runningSession.phase == .failed && runningFixture.calls.isEmpty, "running main app blocks before preflight")
        runningFixture.isMainApplicationRunning = false
        runningSession.begin(removePersonalData: false)
        runningFixture.isMainApplicationRunning = true
        runningSession.confirmUninstall(true)
        check(runningSession.phase == .failed && !runningFixture.calls.contains("uninstall"), "main app restarted after preflight blocks authorization")
        let failedFixture = FakeUninstallExecutor()
        failedFixture.checkResult = .failed("preflight fixture failure")
        let failedSession = UninstallSession(executor: failedFixture)
        failedSession.begin(removePersonalData: false)
        check(failedSession.phase == .failed && failedFixture.calls == ["preflight"], "failed check never reaches confirmation")
        let preview = UninstallSession(executor: PreviewUninstallExecutor())
        preview.begin(removePersonalData: false); preview.confirmUninstall(true)
        check(preview.isPreview && preview.phase == .completed && preview.message.contains("实际文件未改动"), "preview uses synthetic executor throughout")

        let deferredCheck = DeferredUninstallExecutor()
        let checkTimeout = UninstallSession(executor: deferredCheck)
        checkTimeout.begin(removePersonalData: true)
        deferredCheck.checkCallback?(.unresolved("simulated preflight deadline"))
        check(checkTimeout.phase == .unresolved && !checkTimeout.phase.isBusy, "check deadline leaves a closable unresolved state")
        checkTimeout.begin(removePersonalData: true)
        deferredCheck.checkCallback?(.finished(.init(success: true, message: "late check", restartRequired: false)))
        check(checkTimeout.phase == .unresolved && deferredCheck.checkCalls == 1 && deferredCheck.uninstallCalls == 0,
              "late preflight success cannot restart or request confirmation")
        let deferredSystem = DeferredUninstallExecutor()
        let systemTimeout = UninstallSession(executor: deferredSystem)
        systemTimeout.begin(removePersonalData: true)
        deferredSystem.checkCallback?(.finished(.init(success: true, message: "check", restartRequired: false)))
        systemTimeout.confirmUninstall(true)
        deferredSystem.systemCallback?(.unresolved("simulated authorization deadline"))
        check(systemTimeout.phase == .unresolved && !systemTimeout.systemRemovalSucceeded, "authorization deadline is never reported as cancellation or completion")
        systemTimeout.begin(removePersonalData: true)
        deferredSystem.systemCallback?(.finished(.init(success: true, message: "late removal", restartRequired: true)))
        check(systemTimeout.phase == .unresolved && deferredSystem.cleanupCalls == 0 && deferredSystem.uninstallCalls == 1,
              "late uninstall success cannot clean data or enable a retry")

        if let index = CommandLine.arguments.firstIndex(of: "--script-fixture"), CommandLine.arguments.indices.contains(index + 1) {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(appleScript.utf8).write(to: file, options: .atomic)
            print("APPLE_SCRIPT_FIXTURE \(file.path)")
        }
        print("PASS \(checks) uninstaller state/protocol/script checks; no processes, authorization, windows or real cleanup")
    }
}

private final class FakeUninstallExecutor: UninstallExecuting {
    let isPreview = false
    var isMainApplicationRunning = false
    var checkResult: UninstallExecutionResult = .finished(.init(success: true, message: "fixture check", restartRequired: false))
    var system: UninstallExecutionResult = .finished(.init(success: true, message: "fixture system", restartRequired: true))
    var cleanupResult = UserCleanupResult(success: true, message: "fixture preserved")
    var calls: [String] = []
    var cleanupChoices: [Bool] = []
    func preflight(completion: @escaping (UninstallExecutionResult) -> Void) { calls.append("preflight"); completion(checkResult) }
    func uninstall(completion: @escaping (UninstallExecutionResult) -> Void) { calls.append("uninstall"); completion(system) }
    func cleanUserData(removePersonalData: Bool, completion: @escaping (UserCleanupResult) -> Void) {
        calls.append("cleanup"); cleanupChoices.append(removePersonalData); completion(cleanupResult)
    }
}

private final class DeferredUninstallExecutor: UninstallExecuting {
    let isPreview = false
    let isMainApplicationRunning = false
    var checkCallback: ((UninstallExecutionResult) -> Void)?
    var systemCallback: ((UninstallExecutionResult) -> Void)?
    var checkCalls = 0
    var uninstallCalls = 0
    var cleanupCalls = 0
    func preflight(completion: @escaping (UninstallExecutionResult) -> Void) { checkCalls += 1; checkCallback = completion }
    func uninstall(completion: @escaping (UninstallExecutionResult) -> Void) { uninstallCalls += 1; systemCallback = completion }
    func cleanUserData(removePersonalData: Bool, completion: @escaping (UserCleanupResult) -> Void) {
        cleanupCalls += 1; completion(.init(success: true, message: "unexpected fixture cleanup"))
    }
}
