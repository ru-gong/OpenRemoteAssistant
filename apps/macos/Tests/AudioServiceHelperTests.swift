// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

// No installed paths, launchctl, authorization, system process enumeration,
// CoreAudio device query, UI, or audio stream is used by these offline tests.
private var checks = 0
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); expect(false, message) } catch { expect(true, message) }
}

private final class FakeSignature: AudioServiceSignatureChecking {
    var paths: [String] = []
    var failAt: Int?
    var hook: ((String) throws -> Void)?
    func checkBundle(at path: String) throws {
        paths.append(path)
        if paths.count == failAt { throw AudioServiceFailure("injected invalid code signature") }
        try hook?(path)
    }
}
private final class Fixture {
    let root: String
    var aclPaths: [String] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRemote-AudioService-Test-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try directory("/Applications", mode: 0o775)
        try directory("/Library/Audio/Plug-Ins/HAL")
        try write("/sentinel", text: "unrelated fixture data")
        try bundle(.driver); try bundle(.application)
    }
    deinit {
        for path in aclPaths {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-N", path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
        }
        try? FileManager.default.removeItem(atPath: root)
    }
    func path(_ relative: String) -> String { root + relative }
    func directory(_ relative: String, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode])
        guard chmod(path(relative), mode_t(mode)) == 0 else { throw AudioServiceFailure("fixture directory mode failure") }
    }
    func write(_ relative: String, text: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path(relative)))
        guard chmod(path(relative), mode_t(mode)) == 0 else { throw AudioServiceFailure("fixture file mode failure") }
    }
    func bundle(_ bundle: AudioServiceBundle, overrides: [String: Any] = [:]) throws {
        try directory(bundle.path + "/Contents/MacOS")
        var plist: [String: Any] = ["CFBundleIdentifier": bundle.identifier, "CFBundleExecutable": bundle.executable,
            "CFBundlePackageType": bundle.packageType, "CFBundleShortVersionString": bundle.version, "CFBundleVersion": bundle.build]
        plist.merge(overrides) { _, replacement in replacement }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistPath = path(bundle.path + "/Contents/Info.plist")
        try data.write(to: URL(fileURLWithPath: plistPath)); chmod(plistPath, 0o644)
        try write(bundle.path + "/Contents/MacOS/" + bundle.executable, text: "inert fixture, never executed", mode: 0o755)
    }
    func installation(signature: FakeSignature = FakeSignature()) -> AudioServiceInstallation {
        AudioServiceInstallation(rootPath: root, owner: getuid(), applicationsGroup: getgid(), signature: signature)
    }
    func setACL(_ relative: String, rule: String) throws {
        let path = self.path(relative)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", rule, path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AudioServiceFailure("fixture ACL setup failed") }
        aclPaths.append(path)
    }
    func assertUntouched() throws {
        expect(try String(contentsOfFile: path("/sentinel"), encoding: .utf8) == "unrelated fixture data", "unrelated data unchanged")
        expect(FileManager.default.fileExists(atPath: path(AudioServiceBundle.driver.path)), "driver fixture not deleted")
        expect(FileManager.default.fileExists(atPath: path(AudioServiceBundle.application.path)), "application fixture not deleted")
    }
}

private final class FakeInstallation: AudioServiceInstallationChecking {
    var calls = 0
    var failAt: Int?
    func checkInstalled() throws { calls += 1; if calls == failAt { throw AudioServiceFailure("installation changed") } }
}
private final class FakeProcesses: AudioServiceProcessChecking {
    var calls = 0
    var failAt: Int?
    func checkNoConflict() throws { calls += 1; if calls == failAt { throw AudioServiceFailure("concurrent installer") } }
}
private final class FakeRequest: AudioServiceRequestSending {
    var calls = 0
    var fail = false
    var outcome = AudioServiceDispatchOutcome.sent(AudioServiceDiagnostic(method: "fake"))
    func sendReloadRequest() throws -> AudioServiceDispatchOutcome {
        calls += 1
        if fail { throw AudioServiceFailure("request result is unavailable") }
        return outcome
    }
}
private final class FakeReadiness: AudioServiceReadinessChecking {
    var value = AudioServiceReadiness.reloadRequired
    var fail = false
    var calls = 0
    func state() throws -> AudioServiceReadiness {
        calls += 1
        if fail { throw AudioServiceFailure("readiness query failed") }
        return value
    }
}
private final class FakeEndpoints: AudioServiceEndpointReading {
    var compatibility: VoiceAudioCatalogCompatibility?
    var registered: [String: Bool] = [VoiceAudioCatalog.inputUID: false, VoiceAudioCatalog.outputUID: false]
    var queries: [String] = []
    func catalogCompatibility() -> VoiceAudioCatalogCompatibility? { compatibility }
    func isRegistered(_ uid: String) throws -> Bool {
        queries.append(uid)
        guard let value = registered[uid] else { throw AudioServiceFailure("UID query unavailable") }
        return value
    }
}
private final class FakeProcessReader: AudioServiceProcessReading {
    var values: [AudioServiceProcess] = []
    var fail = false
    func snapshot() throws -> [AudioServiceProcess] {
        if fail { throw AudioServiceFailure("process snapshot failed") }
        return values
    }
}
private let daemonIdentity = CoreAudioProcessIdentity(pid: 1234, parentPID: 1, uid: 202, realUID: 202, savedUID: 202,
    executablePath: "/usr/sbin/coreaudiod", startSeconds: 12345678, startMicroseconds: 123)
private final class FakeSystemAssets: CoreAudioSystemAssetChecking {
    var calls = 0
    var fail = false
    func validate() throws { calls += 1; if fail { throw AudioServiceFailure("invalid system plist or signature") } }
}
private final class FakeIdentityReader: CoreAudioIdentityReading {
    var expectedUID: UInt32 = 202
    var values = [daemonIdentity]
    var current = daemonIdentity
    var reads = 0
    var failRead = false
    var failCandidates = false
    func systemAccountUID() throws -> UInt32 { expectedUID }
    func candidates() throws -> [CoreAudioProcessIdentity] {
        if failCandidates { throw AudioServiceFailure("incomplete process list") }
        return values
    }
    func identity(pid: Int32) throws -> CoreAudioProcessIdentity {
        reads += 1
        if failRead { throw AudioServiceFailure("target vanished or inaccessible") }
        return current
    }
}
private final class FakeSignal: CoreAudioSignalSending {
    var calls: [CoreAudioProcessIdentity] = []
    var result = CoreAudioSignalResult(returnCode: 0, errorNumber: 0)
    func send(to identity: CoreAudioProcessIdentity) -> CoreAudioSignalResult {
        calls.append(identity); return result
    }
}

@main enum AudioServiceHelperTests {
    static func main() throws {
        try coordinatorCases()
        try installationCases()
        try permissionAndLinkCases()
        try signatureAndRaceCases()
        try processCases()
        try kernelSnapshotCases()
        try signalCases()
        try systemAssetCases()
        try readinessCases()
        print("AudioServiceHelperTests: \(checks) checks passed; only temporary fixtures and fake requests, no real audio service reload or installed paths touched.")
    }

    static func coordinatorCases() throws {
        do {
            let installed = FakeInstallation(), processes = FakeProcesses(), request = FakeRequest()
            let coordinator = AudioServiceCoordinator(installation: installed, processes: processes, sender: request, readiness: FakeReadiness())
            let preflight = coordinator.run(mode: .preflight, effectiveUID: 501)
            expect(preflight.success && !preflight.requestSent, "non-root preflight only verifies")
            expect(installed.calls == 1 && processes.calls == 1 && request.calls == 0, "preflight never requests reload")
            let denied = coordinator.run(mode: .reload, effectiveUID: 501)
            expect(!denied.success && !denied.requestSent, "non-root reload rejected")
            expect(installed.calls == 1 && processes.calls == 1 && request.calls == 0, "non-root rejection before any extra side effects")
            let sent = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(sent.success && sent.requestSent && sent.phase == "request-sent", "root mock dispatch reports request only")
            expect(installed.calls == 3 && processes.calls == 3 && request.calls == 1, "root revalidates and dispatches exactly once")
            expect(sent.message.contains("尚未确认"), "success does not claim microphone ready")
            let repeated = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(!repeated.success && !repeated.requestSent && request.calls == 1, "repeated operation cannot dispatch twice")
            let data = try JSONEncoder().encode(sent)
            let result = try JSONDecoder().decode(AudioServiceResult.self, from: data)
            expect(result.success && result.requestSent && result.message == sent.message, "UI JSON result contract")
        }
        for source in ["installation", "process"] {
            for point in [1, 2] {
                let installed = FakeInstallation(), processes = FakeProcesses(), request = FakeRequest()
                if source == "installation" { installed.failAt = point } else { processes.failAt = point }
                let result = AudioServiceCoordinator(installation: installed, processes: processes, sender: request, readiness: FakeReadiness()).run(mode: .reload, effectiveUID: 0)
                expect(!result.success && !result.requestSent && request.calls == 0, "\(source) failure at \(point) blocks dispatch")
            }
        }
        do {
            let request = FakeRequest(); request.fail = true
            let coordinator = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(), sender: request, readiness: FakeReadiness())
            let result = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(!result.success && !result.requestSent && request.calls == 1, "request failure is not success")
            expect(result.message.contains("未确认成功"), "failed or timed-out dispatch is explicitly uncertain")
            expect(!result.message.contains("未发送重载请求"), "uncertain dispatch does not claim no signal was sent")
            expect(result.phase == "request_unknown", "uncertain dispatch has explicit UI lockout phase")
            _ = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(request.calls == 1, "failed request never automatically repeated")
        }
    }

    static func installationCases() throws {
        do {
            let fixture = try Fixture(), signature = FakeSignature()
            try fixture.installation(signature: signature).checkInstalled()
            expect(signature.paths == [fixture.path(AudioServiceBundle.driver.path), fixture.path(AudioServiceBundle.application.path)], "both fixed signed bundles verified")
            try fixture.assertUntouched()
        }
        for bundle in [AudioServiceBundle.driver, .application] {
            for change: [String: Any] in [["CFBundleIdentifier": "other.vendor"], ["CFBundleExecutable": "other"],
                ["CFBundlePackageType": "other"], ["CFBundleShortVersionString": "0.0.0"], ["CFBundleVersion": "0"], ["CFBundleVersion": 3]] {
                let fixture = try Fixture(); try fixture.bundle(bundle, overrides: change)
                rejects("wrong bundle identity/version/type rejected: \(bundle.identifier) \(change)") { try fixture.installation().checkInstalled() }
                try fixture.assertUntouched()
            }
            for missing in ["", "/Contents/Info.plist", "/Contents/MacOS/" + bundle.executable] {
                let fixture = try Fixture()
                try FileManager.default.removeItem(atPath: fixture.path(bundle.path + missing))
                rejects("missing component rejected: \(bundle.identifier) \(missing)") { try fixture.installation().checkInstalled() }
            }
        }
        do {
            let fixture = try Fixture()
            try fixture.bundle(.application, overrides: ["CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2"])
            rejects("old 0.1.1 app is not accepted by 0.1.3 helper") { try fixture.installation().checkInstalled() }
            try fixture.bundle(.application, overrides: ["CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3"])
            rejects("old 0.1.2 app is not accepted by 0.1.3 helper") { try fixture.installation().checkInstalled() }
        }
        do {
            let fixture = try Fixture()
            try fixture.write(AudioServiceBundle.driver.path + "/Contents/MacOS/OpenRemoteAudio", text: "", mode: 0o755)
            rejects("empty executable rejected") { try fixture.installation().checkInstalled() }
        }
    }

    static func permissionAndLinkCases() throws {
        for scenario in ["root-writable", "HAL-writable", "bundle-writable", "file-writable", "file-not-executable", "parent-symlink", "bundle-symlink", "nested-symlink", "plist-symlink", "hardlink", "fifo", "quarantine"] {
            let fixture = try Fixture()
            let app = AudioServiceBundle.application.path
            let exe = fixture.path(app + "/Contents/MacOS/OpenRemoteAssistant")
            switch scenario {
            case "root-writable": expect(chmod(fixture.root, 0o777) == 0, "fixture root permissions")
            case "HAL-writable": expect(chmod(fixture.path("/Library/Audio/Plug-Ins/HAL"), 0o775) == 0, "fixture parent permissions")
            case "bundle-writable": expect(chmod(fixture.path(app), 0o775) == 0, "fixture bundle permissions")
            case "file-writable": expect(chmod(exe, 0o775) == 0, "fixture file permissions")
            case "file-not-executable": expect(chmod(exe, 0o644) == 0, "fixture execute permissions")
            case "parent-symlink":
                try FileManager.default.moveItem(atPath: fixture.path("/Applications"), toPath: fixture.path("/Applications-original"))
                expect(symlink(fixture.path("/Applications-original"), fixture.path("/Applications")) == 0, "fixture parent symlink")
            case "bundle-symlink":
                try FileManager.default.moveItem(atPath: fixture.path(app), toPath: fixture.path("/original-app"))
                expect(symlink(fixture.path("/original-app"), fixture.path(app)) == 0, "fixture bundle symlink")
            case "nested-symlink": expect(symlink(fixture.path("/sentinel"), fixture.path(app + "/Contents/link")) == 0, "fixture nested symlink")
            case "plist-symlink":
                try FileManager.default.moveItem(atPath: fixture.path(app + "/Contents/Info.plist"), toPath: fixture.path("/original-plist"))
                expect(symlink(fixture.path("/original-plist"), fixture.path(app + "/Contents/Info.plist")) == 0, "fixture plist symlink")
            case "hardlink": expect(link(fixture.path("/sentinel"), fixture.path(app + "/Contents/hardlink")) == 0, "fixture hardlink")
            case "fifo": expect(mkfifo(fixture.path(app + "/Contents/pipe"), 0o600) == 0, "fixture FIFO")
            case "quarantine": try fixture.directory("/Library/Audio/Plug-Ins/HAL/.OpenRemoteUninstall-previous", mode: 0o700)
            default: break
            }
            let request = FakeRequest()
            let result = AudioServiceCoordinator(installation: fixture.installation(), processes: FakeProcesses(), sender: request, readiness: FakeReadiness()).run(mode: .reload, effectiveUID: 0)
            expect(!result.success && request.calls == 0, "\(scenario) refuses reload")
            try fixture.assertUntouched()
        }
        do {
            let fixture = try Fixture()
            let installation = AudioServiceInstallation(rootPath: fixture.root, owner: getuid() + 1, applicationsGroup: getgid(), signature: FakeSignature())
            rejects("unexpected owner rejected") { try installation.checkInstalled() }
        }
        for (rule, allowed) in [("everyone deny execute", true), ("everyone allow read", false)] {
            let fixture = try Fixture()
            try fixture.setACL(AudioServiceBundle.driver.path + "/Contents/Info.plist", rule: rule)
            if allowed { try fixture.installation().checkInstalled(); expect(true, "deny-only ACL remains acceptable") }
            else { rejects("extended allow ACL rejected") { try fixture.installation().checkInstalled() } }
        }
    }

    static func signatureAndRaceCases() throws {
        for point in [1, 2] {
            let fixture = try Fixture(), signature = FakeSignature(), request = FakeRequest()
            signature.failAt = point
            let result = AudioServiceCoordinator(installation: fixture.installation(signature: signature), processes: FakeProcesses(), sender: request, readiness: FakeReadiness()).run(mode: .reload, effectiveUID: 0)
            expect(!result.success && request.calls == 0, "invalid signature \(point) prevents request")
            try fixture.assertUntouched()
        }
        do {
            let fixture = try Fixture(), signature = FakeSignature()
            signature.hook = { path in
                if path == fixture.path(AudioServiceBundle.application.path) {
                    try FileManager.default.moveItem(atPath: path, toPath: fixture.path("/original-app"))
                    try fixture.bundle(.application)
                }
            }
            rejects("bundle replacement during signature validation rejected") { try fixture.installation(signature: signature).checkInstalled() }
            expect(FileManager.default.fileExists(atPath: fixture.path("/original-app/Contents/Info.plist")), "replaced original never deleted")
        }
        do {
            let fixture = try Fixture(), signature = FakeSignature()
            signature.hook = { path in
                if path == fixture.path(AudioServiceBundle.driver.path) {
                    try fixture.bundle(.driver, overrides: ["CFBundleVersion": "99"])
                }
            }
            rejects("metadata changed during signature check rejected") { try fixture.installation(signature: signature).checkInstalled() }
        }
    }

    static func processCases() throws {
        let reader = FakeProcessReader()
        reader.values = [.init(pid: 1, name: "OpenRemoteAudioServiceHelper", fullPathAvailable: true),
            .init(pid: 2, name: "OpenRemoteAssistant", fullPathAvailable: true),
            .init(pid: 3, name: "installd", fullPathAvailable: true)]
        try AudioServiceProcesses(reader: reader, ownPID: 1).checkNoConflict()
        expect(true, "current helper/main app/idle installation daemon allowed")
        for name in ["Installer", "installer", "OpenRemoteUninstaller", "OpenRemoteUninstallHelper", "OpenRemoteAudioServiceHelper"] {
            reader.values = [.init(pid: 2, name: name, fullPathAvailable: true)]
            rejects("conflicting \(name) rejected") { try AudioServiceProcesses(reader: reader, ownPID: 1).checkNoConflict() }
        }
        for name in ["OpenRemoteUninst", "OpenRemoteAudioS", "OpenRemoteAudio"] {
            reader.values = [.init(pid: 2, name: name, fullPathAvailable: false)]
            rejects("ambiguous truncated \(name) rejected") { try AudioServiceProcesses(reader: reader, ownPID: 1).checkNoConflict() }
        }
        reader.fail = true
        rejects("unavailable process list is fail closed") { try AudioServiceProcesses(reader: reader, ownPID: 1).checkNoConflict() }
    }

    static func signalCases() throws {
        expect(CoreAudioPOSIXSignal.fixedSignal == SIGTERM && CoreAudioPOSIXSignal.fixedSignal != SIGKILL,
               "production adapter uses one graceful SIGTERM and never the forced-kill fallback")
        do {
            let assets = FakeSystemAssets(), reader = FakeIdentityReader(), signal = FakeSignal()
            let target = CoreAudioTargetValidator(assets: assets, reader: reader)
            let result = try FixedAudioServiceRequest(target: target, signal: signal).sendReloadRequest()
            guard case .sent(let diagnostic) = result else { expect(false, "valid target produces sent result"); return }
            expect(signal.calls == [daemonIdentity], "only one exact positive PID identity reaches signal adapter")
            expect(reader.reads == 1 && assets.calls == 1, "system assets then second process identity read required")
            expect(diagnostic.method == "posix_sigterm" && diagnostic.targetPID == daemonIdentity.pid
                   && diagnostic.targetUID == 202 && diagnostic.returnCode == 0,
                   "bounded SIGTERM system target diagnostic recorded")
        }
        for identity in invalidDaemonIdentities() {
            let reader = FakeIdentityReader(), signal = FakeSignal(); reader.values = [identity]; reader.current = identity
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "invalid identity must be rejected before request"); return }
            expect(signal.calls.isEmpty, "invalid PID/path/UID/parent/birth never reaches signal")
        }
        for values in [[], [daemonIdentity, daemonIdentity]] {
            let reader = FakeIdentityReader(), signal = FakeSignal(); reader.values = values
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "zero or multiple targets must be rejected"); return }
            expect(signal.calls.isEmpty, "zero/multiple matches never broaden into a group signal")
        }
        for changed in invalidDaemonIdentities() + [identityWith(startSeconds: daemonIdentity.startSeconds + 1), identityWith(startMicroseconds: 456), identityWith(pid: 5678)] {
            let reader = FakeIdentityReader(), signal = FakeSignal(); reader.current = changed
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "changed target must be rejected"); return }
            expect(signal.calls.isEmpty, "second identity mismatch prevents signal and fallback")
        }
        for error in [EPERM, ESRCH, EINVAL] {
            let reader = FakeIdentityReader(), signal = FakeSignal(); signal.result = .init(returnCode: -1, errorNumber: error)
            let sender = FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal)
            let coordinator = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(), sender: sender, readiness: FakeReadiness())
            let result = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(!result.success && !result.requestSent && result.phase == "request_rejected", "documented POSIX rejection does not lock as unknown")
            expect(result.diagnostic?.errorNumber == error && result.diagnostic?.afterCheck == "same_identity", "exact errno plus post-rejection identity retained")
            expect(reader.reads == 2 && signal.calls.count == 1, "rejection reads back but never sends a fallback")
            expect(result.message.contains("没有后台重载任务"), "rejection does not claim background mutation continues")
            _ = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(signal.calls.count == 1, "same invocation never dispatches twice after rejection")
        }
        for raw in [CoreAudioSignalResult(returnCode: -1, errorNumber: EINTR), .init(returnCode: 1, errorNumber: 0)] {
            let signal = FakeSignal(); signal.result = raw
            let sender = FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: FakeIdentityReader()), signal: signal)
            let result = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(), sender: sender, readiness: FakeReadiness()).run(mode: .reload, effectiveUID: 0)
            expect(!result.success && !result.requestSent && result.phase == "request_unknown", "undocumented syscall result is not guessed rejected or sent")
            expect(signal.calls.count == 1, "unknown never triggers fallback")
        }
        do {
            let assets = FakeSystemAssets(), signal = FakeSignal(); assets.fail = true
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: assets, reader: FakeIdentityReader()), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "invalid signed system asset rejected"); return }
            expect(signal.calls.isEmpty, "system asset failure prevents signal")
        }
        do {
            let reader = FakeIdentityReader(), signal = FakeSignal(); reader.failRead = true
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "unavailable second read rejected"); return }
            expect(signal.calls.isEmpty, "unavailable target never signaled")
        }
        do {
            let reader = FakeIdentityReader(), signal = FakeSignal(); reader.failCandidates = true
            let result = try FixedAudioServiceRequest(target: CoreAudioTargetValidator(assets: FakeSystemAssets(), reader: reader), signal: signal).sendReloadRequest()
            guard case .rejected = result else { expect(false, "incomplete process list rejected"); return }
            expect(signal.calls.isEmpty, "incomplete process enumeration cannot establish unique target")
        }
        expect(AudioServiceMode(rawValue: "--reload") == .reload && AudioServiceMode(rawValue: "--preflight") == .preflight, "only defined operation flags")
        expect(AudioServiceMode(rawValue: "--uninstall") == nil && AudioServiceMode(rawValue: "--target") == nil, "no alternate operation or target option")
    }

    static func kernelSnapshotCases() throws {
        var valid = kinfo_proc()
        valid.kp_proc.p_pid = daemonIdentity.pid
        valid.kp_eproc.e_ppid = 1
        valid.kp_eproc.e_ucred.cr_uid = 202
        valid.kp_eproc.e_pcred.p_ruid = 202
        valid.kp_eproc.e_pcred.p_svuid = 202
        valid.kp_proc.p_un.__p_starttime.tv_sec = Int(daemonIdentity.startSeconds)
        valid.kp_proc.p_un.__p_starttime.tv_usec = Int32(daemonIdentity.startMicroseconds)
        func decode(_ info: kinfo_proc, status: Int32 = 0, bytes: Int = MemoryLayout<kinfo_proc>.size,
            error: Int32 = 0, requestedPID: Int32 = daemonIdentity.pid,
            executable: String = CoreAudioProcessIdentity.executable) throws -> CoreAudioProcessIdentity {
            try CoreAudioKernelSnapshot(info: info, status: status, byteCount: bytes, errorNumber: error)
                .identity(requestedPID: requestedPID, executable: executable)
        }
        expect(try decode(valid) == daemonIdentity, "complete kernel snapshot preserves every required identity field")
        for count in [0, MemoryLayout<kinfo_proc>.size - 1, MemoryLayout<kinfo_proc>.size + 1] {
            rejects("empty, short or changed kernel ABI does not produce an identity") { _ = try decode(valid, bytes: count) }
        }
        for error in [EPERM, ESRCH, ENOMEM] {
            rejects("sysctl failure rejects even apparently complete data") { _ = try decode(valid, status: -1, error: error) }
        }
        for pid: Int32 in [-1, 0, 1, daemonIdentity.pid + 1] {
            rejects("kernel snapshot cannot authorize invalid or mismatched requested PID") { _ = try decode(valid, requestedPID: pid) }
        }
        for pid: Int32 in [-1, 0, 1, daemonIdentity.pid + 1] {
            var invalid = valid; invalid.kp_proc.p_pid = pid
            rejects("kernel returned PID must match exact target") { _ = try decode(invalid) }
        }
        for time: (Int, Int32) in [(-1, 0), (0, 0), (123, -1), (123, 1_000_000)] {
            var invalid = valid
            invalid.kp_proc.p_un.__p_starttime.tv_sec = time.0
            invalid.kp_proc.p_un.__p_starttime.tv_usec = time.1
            rejects("invalid signed timestamp rejects before unsigned conversion") { _ = try decode(invalid) }
        }
        var different = valid
        different.kp_eproc.e_ppid = 77
        different.kp_eproc.e_ucred.cr_uid = 100
        different.kp_eproc.e_pcred.p_ruid = 101
        different.kp_eproc.e_pcred.p_svuid = 102
        let decoded = try decode(different)
        expect(decoded.parentPID == 77 && decoded.uid == 100 && decoded.realUID == 101 && decoded.savedUID == 102,
            "snapshot keeps real, effective and saved UID separate without normalizing them")
        expect(!decoded.matchesSystemDaemon(uid: 202), "untrusted kernel credentials still fail target policy")
        expect(!(try decode(valid, executable: "/tmp/coreaudiod")).matchesSystemDaemon(uid: 202),
            "kernel snapshot does not replace an observed path with the expected path")
    }

    private static func identityWith(pid: Int32 = daemonIdentity.pid, parent: Int32 = 1, uid: UInt32 = 202,
        realUID: UInt32 = 202, savedUID: UInt32 = 202, path: String = CoreAudioProcessIdentity.executable,
        startSeconds: UInt64 = daemonIdentity.startSeconds, startMicroseconds: UInt64 = daemonIdentity.startMicroseconds) -> CoreAudioProcessIdentity {
        .init(pid: pid, parentPID: parent, uid: uid, realUID: realUID, savedUID: savedUID,
            executablePath: path, startSeconds: startSeconds, startMicroseconds: startMicroseconds)
    }
    private static func invalidDaemonIdentities() -> [CoreAudioProcessIdentity] {
        [identityWith(pid: -1), identityWith(pid: 0), identityWith(pid: 1), identityWith(parent: 2), identityWith(uid: 0),
         identityWith(uid: 501), identityWith(realUID: 0), identityWith(savedUID: 0), identityWith(path: "/tmp/coreaudiod"),
         identityWith(startSeconds: 0), identityWith(startMicroseconds: 1_000_000)]
    }

    static func systemAssetCases() throws {
        let systemPlist = "/System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist"
        func create(_ fixture: Fixture, overrides: [String: Any] = [:]) throws {
            try fixture.directory("/System/Library/LaunchDaemons"); try fixture.directory("/usr/sbin")
            var values: [String: Any] = ["Label": "com.apple.audio.coreaudiod", "UserName": "_coreaudiod", "GroupName": "_coreaudiod", "ProgramArguments": ["/usr/sbin/coreaudiod"]]
            values.merge(overrides) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: fixture.path(systemPlist))); chmod(fixture.path(systemPlist), 0o644)
            try fixture.write("/usr/sbin/coreaudiod", text: "inert signed-daemon fixture", mode: 0o755)
        }
        do {
            let fixture = try Fixture(), signature = FakeSignature(); try create(fixture)
            try fixture.installation().checkCoreAudioSystemAssets(appleSignature: signature)
            expect(signature.paths == [fixture.path("/usr/sbin/coreaudiod")], "fixed executable is verified with Apple-specific signature adapter")
            try fixture.assertUntouched()
        }
        for change: [String: Any] in [["Label": "other"], ["UserName": "root"], ["GroupName": "wheel"], ["ProgramArguments": ["/tmp/coreaudiod"]],
            ["ProgramArguments": ["/usr/sbin/coreaudiod", "--other"]], ["Program": "/tmp/coreaudiod"], ["Disabled": true]] {
            let fixture = try Fixture(); try create(fixture, overrides: change)
            rejects("modified system service description rejected") { try fixture.installation().checkCoreAudioSystemAssets(appleSignature: FakeSignature()) }
        }
        for scenario in ["link", "writable", "signature", "missing"] {
            let fixture = try Fixture(), signature = FakeSignature(); try create(fixture)
            switch scenario {
            case "link":
                try FileManager.default.moveItem(atPath: fixture.path("/usr/sbin/coreaudiod"), toPath: fixture.path("/original-daemon"))
                expect(symlink(fixture.path("/original-daemon"), fixture.path("/usr/sbin/coreaudiod")) == 0, "set daemon symlink fixture")
            case "writable": expect(chmod(fixture.path("/usr/sbin/coreaudiod"), 0o775) == 0, "set writable daemon fixture")
            case "signature": signature.failAt = 1
            default: try FileManager.default.removeItem(atPath: fixture.path(systemPlist))
            }
            rejects("unsafe \(scenario) daemon asset rejected") { try fixture.installation().checkCoreAudioSystemAssets(appleSignature: signature) }
        }
    }

    static func readinessCases() throws {
        do {
            let request = FakeRequest(), readiness = FakeReadiness()
            let coordinator = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(), sender: request, readiness: readiness)
            let preflight = coordinator.run(mode: .preflight, effectiveUID: 501)
            expect(preflight.success && readiness.calls == 0, "ordinary preflight does not dispatch or query readiness")
            readiness.value = .ready // The device appears while authorization is pending.
            let result = coordinator.run(mode: .reload, effectiveUID: 0)
            expect(result.success && !result.requestSent && result.phase == "already_ready", "ready during authorization becomes explicit successful no-op")
            expect(readiness.calls == 1 && request.calls == 0, "late readiness checked immediately before any request")
        }
        do {
            let request = FakeRequest(), readiness = FakeReadiness(); readiness.fail = true
            let result = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(), sender: request, readiness: readiness).run(mode: .reload, effectiveUID: 0)
            expect(!result.success && !result.requestSent && request.calls == 0, "readiness query failure prevents reload")
        }
        do {
            let endpoints = FakeEndpoints(); endpoints.compatibility = .current
            expect(try AudioServiceEndpointProbe(reader: endpoints).state() == .ready, "complete Catalog readiness accepted")
            expect(endpoints.queries.isEmpty, "complete Catalog proof needs no ambiguous presence fallback")
        }
        do {
            let endpoints = FakeEndpoints()
            expect(try AudioServiceEndpointProbe(reader: endpoints).state() == .reloadRequired, "only both known absent permits request")
            expect(endpoints.queries == [VoiceAudioCatalog.inputUID, VoiceAudioCatalog.outputUID], "both exact UIDs queried")
        }
        do {
            let endpoints = FakeEndpoints(); endpoints.compatibility = .previousVirtualInput
            expect(try AudioServiceEndpointProbe(reader: endpoints).state() == .reloadRequired,
                   "the exact previous all-Virtual pair permits one explicit reload")
            expect(endpoints.queries.isEmpty, "known previous identity needs no ambiguous presence fallback")
            let request = FakeRequest()
            let result = AudioServiceCoordinator(installation: FakeInstallation(), processes: FakeProcesses(),
                sender: request, readiness: AudioServiceEndpointProbe(reader: endpoints)).run(mode: .reload, effectiveUID: 0)
            expect(result.success && result.requestSent && request.calls == 1,
                   "known previous pair reaches exactly one verified reload request")
        }
        do {
            let endpoints = FakeEndpoints(); endpoints.compatibility = .invalid
            endpoints.registered = [VoiceAudioCatalog.inputUID: true, VoiceAudioCatalog.outputUID: true]
            rejects("invalid complete-looking pair remains fail closed") { _ = try AudioServiceEndpointProbe(reader: endpoints).state() }
            expect(endpoints.queries.isEmpty, "invalid catalog identity is never downgraded to raw UID presence")
        }
        for input in [true, false] {
            for output in [true, false] where input || output {
                let endpoints = FakeEndpoints(); endpoints.registered = [VoiceAudioCatalog.inputUID: input, VoiceAudioCatalog.outputUID: output]
                rejects("partial or mismatching registered endpoints are not unregistered") { _ = try AudioServiceEndpointProbe(reader: endpoints).state() }
            }
        }
        for missing in [VoiceAudioCatalog.inputUID, VoiceAudioCatalog.outputUID] {
            let endpoints = FakeEndpoints(); endpoints.registered[missing] = nil
            rejects("query failure for either UID fails closed") { _ = try AudioServiceEndpointProbe(reader: endpoints).state() }
        }
    }
}
