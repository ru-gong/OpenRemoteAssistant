// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

/// Only synthetic files, injected callbacks and protocol text are used here.
/// Never runs Process, requests authorization, queries real CoreAudio devices,
/// reads the installed driver, opens audio, or calls the installed helper.
@main
enum AudioServiceReloadTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }; checks += 1
        }
        func isUnresolved(_ value: AudioReloadOutcome) -> Bool {
            if case .unresolved = value { return true }; return false
        }
        func isFailed(_ value: AudioReloadOutcome) -> Bool {
            if case .failed = value { return true }; return false
        }
        func isCancelled(_ value: AudioReloadOutcome) -> Bool {
            if case .cancelled = value { return true }; return false
        }
        func accepted(_ value: AudioReloadOutcome) -> Bool {
            if case .response(let response) = value { return response.isAcceptedRequest }; return false
        }
        func response(_ success: Bool = true, _ sent: Bool = false, _ phase: String = "preflight") -> String {
            "{\"success\":\(success),\"requestSent\":\(sent),\"message\":\"fixture result\",\"phase\":\"\(phase)\"}"
        }
        func envelope(_ result: String, exit: Int = 0, cleanup: Bool = true) -> String {
            "{\"helperExit\":\(exit),\"cleanupSucceeded\":\(cleanup),\"result\":\(result)}"
        }
        func interpret(_ output: String, status: Int32 = 0, error: String = "", signal: Bool = false,
                       inputFailed: Bool = false, outputOverflow: Bool = false, errorOverflow: Bool = false,
                       format: AudioReloadOutputFormat = .authorizationEnvelope) -> AudioReloadOutcome {
            AudioReloadProcessRunner.interpret(stdout: .init(data: Data(output.utf8), exceededLimit: outputOverflow),
                stderr: .init(data: Data(error.utf8), exceededLimit: errorOverflow), status: status,
                wasSignal: signal, inputFailed: inputFailed, format: format)
        }

        // Installation classification never treats ambiguous endpoints as an
        // unloaded component, or a valid disk bundle as successful audio input.
        for disk in [AudioDriverDiskState.missing, .invalid("fixture") ] {
            let result = AudioDriverInstallation.classify(disk: disk, catalogReady: true, input: .present, output: .present)
            check(!result.isReady && !result.needsReload, "disk failure cannot authorize reload or claim ready")
        }
        check(AudioDriverInstallation.classify(disk: .installed, catalogReady: false, input: .absent, output: .absent) == .installedUnloaded,
              "only two confirmed absent UIDs offer reload")
        check(AudioDriverInstallation.classify(disk: .installed, catalogReady: false, input: .present, output: .present,
                                               knownPreviousLoaded: true) == .installedStale,
              "fully validated old in-memory endpoints after a disk upgrade offer an explicit reload")
        for input in [AudioEndpointPresence.absent, .present, .queryFailed] {
            for output in [AudioEndpointPresence.absent, .present, .queryFailed] {
                let state = AudioDriverInstallation.classify(disk: .installed, catalogReady: false, input: input, output: output)
                check(state.needsReload == (input == .absent && output == .absent),
                      "raw presence alone never authorizes stale-driver reload")
                check(!state.isReady, "presence is not Catalog identity verification")
            }
        }
        check(!AudioDriverInstallation.classify(disk: .invalid("fixture"), catalogReady: false,
                                                input: .present, output: .present,
                                                knownPreviousLoaded: true).needsReload,
              "known previous live endpoints cannot override an invalid disk bundle")
        check(AudioDriverInstallation.classify(disk: .installed, catalogReady: true, input: .present, output: .present).isReady,
              "accepted Catalog pair is ready")
        check(AudioDriverAvailability.ready.message.contains("不代表已验证遥控器收音"), "endpoint readiness is not real capture acceptance")
        check(AudioDriverAvailability.missing.message.contains("不能补装"), "reload cannot install a missing driver")
        check(AudioDriverInstallation.previewState(arguments: [], plistValue: nil) == .missing, "preview defaults safely missing")
        check(AudioDriverInstallation.previewState(arguments: [], plistValue: "installed-unloaded") == .installedUnloaded, "preview plist supports unloaded")
        check(AudioDriverInstallation.previewState(arguments: [], plistValue: "installed-stale") == .installedStale, "preview plist supports stale loaded endpoints")
        check(AudioDriverInstallation.previewState(arguments: [], plistValue: "ready") == .ready, "preview plist supports ready")
        check(AudioDriverInstallation.previewState(arguments: ["--audio-driver-preview-state", "missing"], plistValue: "ready") == .missing, "explicit preview argument takes precedence")
        check(AudioDriverInstallation.previewState(arguments: ["--audio-driver-preview-state", "unexpected"], plistValue: "ready") == .missing, "unknown preview value is safe")

        let files = try SyntheticFiles()
        defer { files.remove() }
        let driver = files.root.appendingPathComponent("DriverFixture.driver", isDirectory: true)
        check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid(), signatureCheck: { _ in true }) == .missing, "missing fixture classified without real paths")
        try files.makeDriver(at: driver)
        check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid(), signatureCheck: { _ in true }) == .installed, "synthetic metadata passes injected signature")
        check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid(), signatureCheck: { _ in false }) != .installed, "signature failure prevents reload")
        check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid() + 1, signatureCheck: { _ in true }) != .installed, "wrong owner fails")
        for (field, value) in [("CFBundleIdentifier", "other.driver"), ("CFBundleExecutable", "other"),
                               ("CFBundlePackageType", "APPL"), ("CFBundleShortVersionString", "9.0"), ("CFBundleVersion", "99")] {
            try files.makeDriver(at: driver, override: [field: value])
            check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid(), signatureCheck: { _ in true }) != .installed, "incompatible driver identity fails: " + field)
        }
        try files.makeDriver(at: driver)
        let driverExecutable = driver.appendingPathComponent("Contents/MacOS/OpenRemoteAudio")
        chmod(driverExecutable.path, 0o666)
        check(AudioDriverInstallation.inspect(at: driver, expectedOwner: getuid(), signatureCheck: { _ in true }) != .installed, "writable or nonexecutable driver fails")
        try files.makeDriver(at: driver)
        let driverLink = files.root.appendingPathComponent("DriverLink.driver")
        try FileManager.default.createSymbolicLink(at: driverLink, withDestinationURL: driver)
        check(AudioDriverInstallation.inspect(at: driverLink, expectedOwner: getuid(), signatureCheck: { _ in true }) != .installed, "driver symlink fails")

        // The ordinary-user helper check reads a bounded fixed FD, rejects
        // nonregular types without blocking, and never executes its fixture.
        let helper = files.root.appendingPathComponent("inert-helper")
        let bytes = Data("inert helper fixture; never execute".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: helper); chmod(helper.path, 0o700)
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest, expectedOwner: getuid()) == nil, "pinned fixture digest passes")
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest.uppercased(), expectedOwner: getuid()) == nil, "helper digest is case insensitive hex")
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: String(repeating: "a", count: 64), expectedOwner: getuid()) != nil, "wrong helper SHA fails")
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest, expectedOwner: getuid() + 1) != nil, "wrong helper owner fails")
        for mode in [0o600, 0o720, 0o702] {
            chmod(helper.path, mode_t(mode))
            check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest, expectedOwner: getuid()) != nil, "helper execution or write permissions rejected")
        }
        chmod(helper.path, 0o700)
        let helperLink = files.root.appendingPathComponent("inert-helper-link")
        try FileManager.default.createSymbolicLink(at: helperLink, withDestinationURL: helper)
        check(AudioReloadHelperValidation.validationError(at: helperLink, expectedDigest: digest, expectedOwner: getuid()) != nil, "nofollow rejects symlink helper")
        check(AudioReloadHelperValidation.validationError(at: files.root, expectedDigest: digest, expectedOwner: getuid()) != nil, "helper directory rejected")
        let fifo = files.root.appendingPathComponent("inert-helper-fifo")
        guard mkfifo(fifo.path, 0o700) == 0 else { fatalError("fixture FIFO creation failed") }
        check(AudioReloadHelperValidation.validationError(at: fifo, expectedDigest: digest, expectedOwner: getuid()) != nil, "nonblocking regular check rejects FIFO")
        try Data().write(to: helper)
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest, expectedOwner: getuid()) != nil, "empty helper rejected")
        try Data(repeating: 0, count: AudioReloadHelperValidation.maximumBytes + 1).write(to: helper)
        check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: digest, expectedOwner: getuid()) != nil, "helper size bound enforced")
        try bytes.write(to: helper)

        let scriptDigest = String(repeating: "a", count: 64)
        let shell = try AudioReloadScriptBuilder.shellScript(helperSHA256: scriptDigest)
        let appleScript = try AudioReloadScriptBuilder.appleScript(helperSHA256: scriptDigest)
        check(shell.contains("/private/var/tmp/OpenRemote-audio-service-root.XXXXXXXX"), "fixed private staging parent")
        check(shell.contains("umask 077"), "root stage private permissions")
        check(shell.contains("[ ! -L '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper' ]"), "source link check before copy")
        check(shell.contains("[ -f '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper' ]"), "source regular file before copy")
        check(shell.contains("/bin/cp -P '/Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper'"), "only fixed non-dereferencing helper copy")
        check(shell.contains("[ ! -L \"$stage/OpenRemoteAudioServiceHelper\" ]") && shell.contains("[ -f \"$stage/OpenRemoteAudioServiceHelper\" ]"), "copied helper must be regular and not a symlink")
        check(shell.contains("/usr/sbin/chown root:wheel") && shell.contains("/bin/chmod 0500"), "fixed root executable permissions")
        check(shell.contains("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C /usr/bin/shasum"), "digest runs with minimal environment")
        check(shell.contains("[ \"${actual%% *}\" = '" + scriptDigest + "' ]"), "expected digest is pinned")
        check(shell.contains("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \"$stage/OpenRemoteAudioServiceHelper\" --reload"), "helper runs with fixed option and minimal environment")
        check(shell.contains("helper_exit=$?") && shell.contains("cleanupSucceeded"), "nonzero helper result and cleanup preserved")
        check(shell.contains("trap cleanup EXIT") && shell.contains("trap 'exit 143' TERM"), "cleanup covers normal and interrupted execution")
        check(!shell.contains("rm -rf") && !shell.contains("launchctl") && !shell.contains("killall"), "bootstrap has no broad deletion or daemon command")
        check(appleScript.contains("with administrator privileges without altering line endings"), "system authorization preserves JSON lines")
        check(appleScript.contains(AudioReloadScriptBuilder.cancellationMarker), "cancellation uses exact script marker")
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64), String(repeating: "ａ", count: 64), "'; false; #"] {
            check((try? AudioReloadScriptBuilder.shellScript(helperSHA256: invalid)) == nil, "invalid script digest cannot inject shell")
            check(AudioReloadHelperValidation.validationError(at: helper, expectedDigest: invalid, expectedOwner: getuid()) != nil, "invalid digest cannot run ordinary check")
        }
        let uppercaseShell = try AudioReloadScriptBuilder.shellScript(helperSHA256: scriptDigest.uppercased())
        check(uppercaseShell == shell, "script hex normalized")

        let sent = response(true, true, "request")
        let alreadyReady = response(true, false, "already_ready")
        check(accepted(interpret(envelope(sent))), "accepted signal is not inferred from exit alone")
        check(accepted(interpret(envelope(alreadyReady))), "already_ready no-op enters readback")
        check(isUnresolved(interpret(envelope(sent, exit: 1))), "helper exit contradicting success is unknown")
        check(isUnresolved(interpret(envelope(sent, cleanup: false))), "cleanup failure is not success")
        check(isUnresolved(interpret(envelope(sent), status: 1)), "osascript failure cannot carry accepted success")
        check(isUnresolved(interpret(envelope(sent, exit: -1))) && isUnresolved(interpret(envelope(sent, exit: 256))), "invalid exit range rejected")
        check(isUnresolved(interpret(envelope(response(true, false, "preflight")))), "authorization requires request or explicit ready no-op")
        check(isUnresolved(interpret(envelope(response(false, true, "failed"), exit: 1))), "claimed request with failure remains unknown")
        for phase in ["request_unknown", "request", "already-attempted", "already_attempted"] {
            check(isUnresolved(interpret(envelope(response(false, false, phase), exit: 1))), "attempted request failure locks retries: " + phase)
        }
        let knownFailure = interpret(envelope(response(false, false, "preflight"), exit: 1))
        if case .response(let result) = knownFailure { check(!result.success && !result.requestSent, "known prerequisite failure preserved") }
        else { fatalError("known prerequisite failure missing") }
        for malformed in ["", "null", "{}", "log\n" + envelope(sent), envelope(sent) + envelope(sent), envelope("null")] {
            check(isUnresolved(interpret(malformed)), "authorization must return one complete JSON envelope")
        }
        check(isUnresolved(interpret(envelope(sent), signal: true)), "terminated process is not cancellation")
        check(isUnresolved(interpret(envelope(sent), inputFailed: true)), "stdin failure prevents accepted result")
        check(isUnresolved(interpret(envelope(sent), outputOverflow: true)), "oversized stdout rejected")
        check(isUnresolved(interpret(envelope(sent), errorOverflow: true)), "oversized stderr rejected")
        check(isFailed(interpret(sent, format: .preflight)), "preflight must never claim to send a request")
        check(isFailed(interpret(response(), status: 1, format: .preflight)), "preflight success requires zero exit")
        check(isFailed(interpret(envelope(sent), format: .preflight)), "preflight raw protocol distinct from privileged envelope")
        if case .response(let result) = interpret(response(), format: .preflight) {
            check(result.success && !result.requestSent, "valid preflight does not imply signal")
        } else { fatalError("preflight fixture was not accepted") }
        let cancelError = "execution error: OPENREMOTE_AUDIO_AUTH_CANCELLED (-128)"
        check(isCancelled(interpret("", status: 1, error: cancelError)), "explicit OS cancellation recognized")
        for outcome in [interpret("", status: 1, error: "User cancelled (-128)"),
                        interpret("", status: 1, error: cancelError, signal: true),
                        interpret("", status: 1, error: cancelError, inputFailed: true),
                        interpret("", status: 1, error: cancelError, outputOverflow: true),
                        interpret(envelope(sent), status: 1, error: cancelError),
                        interpret("", status: 1, error: cancelError, format: .preflight)] {
            check(!isCancelled(outcome), "only unambiguous authorization cancellation is cancelled")
        }
        let gate = AudioReloadCompletionGate()
        check(gate.claim() && !gate.claim() && !gate.claim(), "deadline and late completion delivered only once")
        check(gate.hasDelivered, "late scheduled worker sees delivered deadline before launching")

        let rejected = interpret(envelope(response(false, false, "request_rejected"), exit: 1))
        if case .response(let result) = rejected {
            check(!result.success && !result.requestSent, "structured completed rejection remains a normal terminal failure")
        } else { fatalError("explicit rejection must not remain unresolved") }
        check(isUnresolved(interpret(envelope(response(false, false, "request_rejected")))), "zero helper exit contradicts rejection")
        check(isUnresolved(interpret(envelope(response(true, true, "request_rejected"), exit: 1))), "rejection cannot claim success or sent signal")
        let tracker = AudioReloadExecutionTracker()
        check(!tracker.hasPendingWork, "new executor has no in-flight work")
        let queued = tracker.begin(), running = tracker.begin()
        check(tracker.hasPendingWork, "queued launch and running process both tracked")
        tracker.finish(running)
        check(tracker.hasPendingWork, "settled process does not hide queued authorization")
        tracker.finish(queued); tracker.finish(queued)
        check(!tracker.hasPendingWork, "only completed work releases in-flight evidence")
        func backgroundActive(_ state: AudioReloadBackgroundState) -> Bool {
            if case .active = state { return true }; return false
        }
        func backgroundUnavailable(_ state: AudioReloadBackgroundState) -> Bool {
            if case .unavailable = state { return true }; return false
        }
        check(AudioReloadBackgroundProbe.classify([]) == .settled, "empty synthetic process snapshot is one piece of settled evidence")
        check(AudioReloadBackgroundProbe.classify([.init(name: "osascript", potentialBootstrap: false, arguments: nil)]) == .settled,
              "unrelated osascript is not a global blocker; exact local invocation is tracked separately")
        check(backgroundActive(AudioReloadBackgroundProbe.classify([.init(name: "OpenRemoteAudioServiceHelper", potentialBootstrap: false, arguments: nil)])), "surviving privileged helper blocks recovery")
        check(backgroundActive(AudioReloadBackgroundProbe.classify([.init(name: "OpenRemoteAudio", potentialBootstrap: false, arguments: nil)])), "truncated helper name stays protected")
        check(backgroundActive(AudioReloadBackgroundProbe.classify([.init(name: "sh", potentialBootstrap: true, arguments: "fixed OpenRemote-audio-service-root.XXXXXXXX bootstrap")])), "surviving bootstrap shell blocks recovery")
        check(backgroundActive(AudioReloadBackgroundProbe.classify([.init(name: "launchctl", potentialBootstrap: true, arguments: "kill SIGTERM system/com.apple.audio.coreaudiod")])), "legacy fixed service command blocks recovery")
        check(AudioReloadBackgroundProbe.classify([.init(name: "sh", potentialBootstrap: true, arguments: "unrelated fixed command")]) == .settled, "unrelated identifiable shell is ignored")
        check(backgroundUnavailable(AudioReloadBackgroundProbe.classify([.init(name: "sh", potentialBootstrap: true, arguments: nil)])), "unidentifiable privileged shell fails closed")
        check(backgroundActive(AudioReloadBackgroundProbe.classify([], stagingPresent: true)), "orphaned root-private stage blocks protected recovery")
        check(backgroundUnavailable(AudioReloadBackgroundProbe.classify([], stagingQuerySucceeded: false)), "staging parent query failure is not settled evidence")

        // Coordinator fixture: no background clocks, real process or hardware.
        for initial in [AudioDriverAvailability.missing, .invalid("fixture"), .unavailable("fixture"), .ready] {
            let f = ReloadFixture([initial]); f.coordinator.begin()
            check(f.executor.events == ["inspect"], "unsuitable or ready initial state never stops or authorizes")
            check(f.coordinator.phase == (initial == .ready ? .ready : .failed), "fresh initial decision")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .ready]); f.coordinator.begin()
            check(f.executor.events == ["inspect", "stop", "preflight", "inspect"], "second readiness check prevents unnecessary authorization")
            check(f.coordinator.phase == .ready && f.coordinator.didStopOwnActivities, "already active after stop remains stopped")
            check(!f.coordinator.requestWasSent, "no signal for independently activated driver")
        }
        do {
            let f = ReloadFixture([.installedStale, .installedStale]); f.executor.reloadOutcome = .cancelled
            f.coordinator.begin()
            check(f.executor.events == ["inspect", "stop", "preflight", "inspect", "authorize"],
                  "stale loaded endpoints follow the same explicit guarded reload path")
            check(f.coordinator.phase == .cancelled && f.executor.authorizationCount == 1,
                  "stale endpoint recovery never reloads without authorization")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded, nil]); f.executor.deferStop = true
            f.coordinator.begin()
            check(f.coordinator.phase == .stopping && f.executor.events == ["inspect", "stop"], "preflight waits for asynchronous shutdown")
            f.executor.completeStop()
            check(f.executor.events == ["inspect", "stop", "preflight", "inspect", "authorize", "inspect"], "shutdown precedes preflight and authorization")
            check(f.coordinator.phase == .verifying && f.coordinator.requestWasSent, "signal alone only starts readback")
            check(f.coordinator.phase.blocksActions, "enable and uninstall blocked during readback")
            f.executor.completeInspection(.ready)
            check(f.coordinator.phase == .ready && !f.coordinator.phase.blocksActions, "validated two endpoints finish readiness")
            check(f.coordinator.message.contains("保持关闭") && f.coordinator.message.contains("尚未验证实体遥控器收音"), "ready never auto-restores or claims capture")
            check(f.scheduler.liveCount == 0, "readiness cancels obsolete deadlines")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded, nil])
            f.executor.reloadOutcome = .response(.init(success: true, requestSent: false, message: "no-op", phase: "already_ready"))
            f.coordinator.begin()
            check(f.coordinator.phase == .verifying && !f.coordinator.requestWasSent, "already_ready still needs independent readback")
            f.executor.completeInspection(.ready)
            check(f.coordinator.phase == .ready && f.executor.authorizationCount == 1, "ready no-op never submits again")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded, .unavailable("identity mismatch"), nil])
            f.coordinator.begin()
            check(f.coordinator.phase == .verifying, "mismatched endpoint cannot finish verification")
            check(f.scheduler.fire(1), "readback polls using injected scheduler")
            check(f.scheduler.fire(25), "25-second verification deadline exists")
            check(f.coordinator.phase == .verificationTimedOut, "bounded verification does not claim ready")
            f.executor.completeInspection(.ready)
            check(f.coordinator.phase == .verificationTimedOut, "late ready callback cannot advance timed-out operation")
            check(f.executor.authorizationCount == 1 && f.scheduler.liveCount == 0, "no automatic retry or leftover poll")
            f.executor.inspections = [nil]; f.coordinator.begin()
            check(f.coordinator.phase == .checking, "manual new action starts fresh inspection")
            f.executor.completeInspection(.ready)
            check(f.coordinator.phase == .ready && f.executor.authorizationCount == 1, "fresh ready state skips another signal")
        }
        do {
            let f = ReloadFixture([nil]); f.coordinator.begin()
            check(f.scheduler.fire(5) && f.coordinator.phase == .unresolved, "initial query has bounded unresolved deadline")
            f.executor.completeInspection(.installedUnloaded); f.coordinator.begin()
            check(f.executor.events == ["inspect"] && f.coordinator.phase.blocksActions, "late initial query and new begin cannot proceed")
        }
        do {
            let f = ReloadFixture([.installedUnloaded]); f.executor.deferStop = true; f.coordinator.begin()
            check(f.scheduler.fire(5) && f.coordinator.phase == .unresolved, "unconfirmed shutdown blocks authorization")
            f.executor.completeStop(); f.coordinator.begin()
            check(f.executor.events == ["inspect", "stop"], "late shutdown cannot preflight or authorize")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, nil]); f.coordinator.begin()
            check(f.coordinator.phase == .rechecking, "fresh pre-authorization state may await query")
            check(f.scheduler.fire(5) && f.coordinator.phase == .unresolved, "fresh query also bounded")
            f.executor.completeInspection(.installedUnloaded)
            check(f.executor.authorizationCount == 0, "late fresh query cannot authorize")
        }
        for unknownPhase in ["request_unknown", "request", "already-attempted"] {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded])
            f.executor.reloadOutcome = interpret(envelope(response(false, false, unknownPhase), exit: 1))
            f.coordinator.begin(); f.coordinator.begin()
            check(f.coordinator.phase == .unresolved && f.coordinator.phase.blocksActions, "uncertain helper result locks coordinator")
            check(f.executor.authorizationCount == 1, "uncertain request cannot be retried")
        }
        do {
            let f = ReloadFixture([.installedUnloaded]); f.executor.preflightOutcome = .unresolved("fake timeout")
            f.coordinator.begin(); f.coordinator.begin()
            check(f.coordinator.phase == .unresolved && f.executor.authorizationCount == 0, "preflight timeout blocks future requests")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = nil
            f.coordinator.begin()
            check(f.coordinator.phase == .authorizing, "authorization remains pending")
            f.executor.completeReload(.unresolved("fake authorization deadline"))
            f.executor.completeReload(.response(.init(success: true, requestSent: true, message: "late", phase: "request")))
            f.coordinator.begin()
            check(f.coordinator.phase == .unresolved && f.executor.authorizationCount == 1, "late authorization result never advances timed-out phase")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = .cancelled
            f.coordinator.begin()
            check(f.coordinator.phase == .cancelled && !f.coordinator.requestWasSent, "explicit cancellation is separate from installation failure")
            check(f.coordinator.didStopOwnActivities && f.coordinator.message.contains("保持停止"), "cancelled authorization does not resume input or audio")
            check(f.executor.authorizationCount == 1 && f.scheduler.liveCount == 0, "cancellation never retries itself")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = knownFailure
            f.coordinator.begin()
            check(f.coordinator.phase == .failed && !f.coordinator.phase.blocksActions, "known pre-request failure may be retried manually")
            check(f.executor.authorizationCount == 1 && f.scheduler.liveCount == 0, "known failure does not automatically retry")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = rejected
            f.coordinator.begin()
            check(f.coordinator.phase == .failed && !f.coordinator.phase.isBusy && !f.coordinator.phase.blocksActions,
                  "completed system rejection releases ordinary controls")
            check(f.coordinator.message.contains("未执行重载") && f.coordinator.message.contains("不会自动恢复"), "rejection accurately explains no reload and no restore")
            check(f.executor.authorizationCount == 1 && f.scheduler.liveCount == 0, "rejection never repeats the request")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = .unresolved("legacy request_unknown")
            f.coordinator.begin(); f.executor.backgroundOutcome = .active("authorization still running")
            f.coordinator.checkRecovery()
            check(f.coordinator.phase == .unresolved && f.coordinator.phase.blocksActions, "active old authorization keeps protected operations blocked")
            f.executor.backgroundOutcome = .unavailable("snapshot failed"); f.coordinator.checkRecovery()
            check(f.coordinator.phase == .unresolved, "failed read-only check is retryable but not permission to unlock")
            f.executor.backgroundOutcome = .settled; f.coordinator.checkRecovery()
            check(f.coordinator.phase == .recovered && !f.coordinator.phase.blocksActions, "settled invocation restores ordinary controls")
            check(f.coordinator.phase.blocksReload, "recovered uncertainty still forbids another request in this flow")
            check(f.coordinator.message.contains("仍未确认") && f.coordinator.message.contains("不会自动恢复"), "recovery never reclassifies old unknown as successful")
            let events = f.executor.events
            f.coordinator.begin(); f.coordinator.checkRecovery()
            check(f.executor.events == events && f.executor.authorizationCount == 1, "recovery only reads and cannot restart authorization")
            f.executor.completeReload(.response(.init(success: true, requestSent: true, message: "late", phase: "request-sent")))
            check(f.coordinator.phase == .recovered, "late old authorization cannot override recovered generation")
        }
        do {
            let f = ReloadFixture([.installedUnloaded, .installedUnloaded]); f.executor.reloadOutcome = .unresolved("legacy failure")
            f.executor.backgroundOutcome = nil; f.coordinator.begin(); f.coordinator.checkRecovery()
            check(f.coordinator.phase == .recovering && f.coordinator.phase.isBusy, "read-only recovery has explicit progress")
            check(f.scheduler.fire(5) && f.coordinator.phase == .unresolved, "recovery query bounded to five seconds")
            f.executor.completeBackground(.settled)
            check(f.coordinator.phase == .unresolved, "late recovery evidence cannot clear protection")
            f.executor.backgroundOutcome = .settled; f.coordinator.checkRecovery()
            check(f.coordinator.phase == .recovered && f.executor.authorizationCount == 1, "explicit fresh read-only retry may recover without request")
        }
        for state in [AudioDriverAvailability.missing, .installedUnloaded, .installedStale, .ready] {
            let preview = PreviewAudioServiceReloadExecutor(availability: state)
            let clock = FakeScheduler()
            let coordinator = AudioServiceReloadCoordinator(executor: preview, schedule: clock.schedule)
            coordinator.begin()
            check(preview.isPreview && coordinator.message.hasPrefix("【预览模拟】"), "preview is an injected no-system executor")
            check(coordinator.phase == (state == .missing ? .failed : .ready), "preview can show all installation scenarios")
        }
        for scenario in [AudioReloadPreviewScenario.rejected, .unknownRecoverable, .unknownBusy] {
            let preview = PreviewAudioServiceReloadExecutor(availability: .installedUnloaded, scenario: scenario)
            let clock = FakeScheduler()
            let coordinator = AudioServiceReloadCoordinator(executor: preview, schedule: clock.schedule)
            coordinator.begin()
            check(coordinator.phase == (scenario == .rejected ? .failed : .unresolved), "preview exposes rejection and compatibility unknown scenarios")
            coordinator.checkRecovery()
            check(coordinator.phase == (scenario == .rejected ? .failed : scenario == .unknownRecoverable ? .recovered : .unresolved), "preview recovery is synthetic and scenario-specific")
            check(preview.availability == .installedUnloaded, "failed/unknown preview does not turn endpoints ready")
        }
        check(AudioReloadPreviewScenario.selected(arguments: [], plistValue: "unknown-recoverable") == .unknownRecoverable, "preview recovery scenario from bundle flag")
        check(AudioReloadPreviewScenario.selected(arguments: ["--audio-reload-preview-scenario", "rejected"], plistValue: "unknown-busy") == .rejected, "explicit preview scenario takes precedence")
        if let index = CommandLine.arguments.firstIndex(of: "--write-script-fixture"), CommandLine.arguments.indices.contains(index + 1) {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try appleScript.write(to: destination, atomically: true, encoding: .utf8)
        }
        print("AudioServiceReloadTests: \(checks) checks passed; fake callbacks and synthetic files only; no process, authorization, reload or audio device access.")
    }
}

private final class SyntheticFiles {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRemote-Reload-Fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func makeDriver(at url: URL, override: [String: String] = [:]) throws {
        let executableDirectory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var info: [String: String] = ["CFBundleIdentifier": "org.rc001remote.audio", "CFBundleExecutable": "OpenRemoteAudio",
            "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2"]
        info.merge(override) { _, new in new }
        let plist = url.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        chmod(plist.path, 0o644)
        let executable = executableDirectory.appendingPathComponent("OpenRemoteAudio")
        try Data("inert synthetic driver fixture; never execute".utf8).write(to: executable)
        chmod(executable.path, 0o755)
    }
}

private final class FakeScheduler {
    private final class Item {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(_ delay: TimeInterval, _ action: @escaping () -> Void) { self.delay = delay; self.action = action }
    }
    private var items: [Item] = []
    var liveCount: Int { items.filter { !$0.cancelled }.count }
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> AudioReloadScheduledTask {
        let item = Item(delay, action); items.append(item)
        return AudioReloadScheduledTask { item.cancelled = true }
    }
    @discardableResult func fire(_ delay: TimeInterval) -> Bool {
        guard let item = items.first(where: { !$0.cancelled && $0.delay == delay }) else { return false }
        item.cancelled = true; item.action(); return true
    }
}

private final class FakeReloadExecutor: AudioServiceReloadExecuting {
    let isPreview = false
    var events: [String] = []
    var inspections: [AudioDriverAvailability?]
    var deferStop = false
    var preflightOutcome: AudioReloadOutcome? = .response(.init(success: true, requestSent: false, message: "preflight", phase: "preflight"))
    var reloadOutcome: AudioReloadOutcome? = .response(.init(success: true, requestSent: true, message: "request", phase: "request"))
    private var inspectionCompletions: [(AudioDriverAvailability) -> Void] = []
    private var stopCompletion: (() -> Void)?
    private var reloadCompletion: ((AudioReloadOutcome) -> Void)?
    var backgroundOutcome: AudioReloadBackgroundState? = .settled
    private var backgroundCompletion: ((AudioReloadBackgroundState) -> Void)?
    var authorizationCount: Int { events.filter { $0 == "authorize" }.count }
    init(_ inspections: [AudioDriverAvailability?]) { self.inspections = inspections }
    func inspect(completion: @escaping (AudioDriverAvailability) -> Void) {
        events.append("inspect")
        if !inspections.isEmpty, let value = inspections.removeFirst() { completion(value) }
        else { inspectionCompletions.append(completion) }
    }
    func stopOwnActivities(completion: @escaping () -> Void) {
        events.append("stop")
        if deferStop { stopCompletion = completion } else { completion() }
    }
    func preflight(completion: @escaping (AudioReloadOutcome) -> Void) {
        events.append("preflight"); if let preflightOutcome { completion(preflightOutcome) }
    }
    func requestReload(completion: @escaping (AudioReloadOutcome) -> Void) {
        events.append("authorize"); reloadCompletion = completion
        if let reloadOutcome { completion(reloadOutcome) }
    }
    func completeInspection(_ value: AudioDriverAvailability) {
        guard !inspectionCompletions.isEmpty else { fatalError("no pending inspection") }
        inspectionCompletions.removeFirst()(value)
    }
    func completeStop() { stopCompletion?() }
    func completeReload(_ outcome: AudioReloadOutcome) { reloadCompletion?(outcome) }
    func checkBackgroundActivity(completion: @escaping (AudioReloadBackgroundState) -> Void) {
        events.append("background"); backgroundCompletion = completion
        if let backgroundOutcome { completion(backgroundOutcome) }
    }
    func completeBackground(_ state: AudioReloadBackgroundState) { backgroundCompletion?(state) }
}

private final class ReloadFixture {
    let executor: FakeReloadExecutor
    let scheduler = FakeScheduler()
    let coordinator: AudioServiceReloadCoordinator
    init(_ inspections: [AudioDriverAvailability?]) {
        executor = FakeReloadExecutor(inspections)
        coordinator = AudioServiceReloadCoordinator(executor: executor, schedule: scheduler.schedule)
    }
}
