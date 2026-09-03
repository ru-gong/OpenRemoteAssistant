// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CoreAudio

// Offline only: filesystem mutations stay under a newly created temp fixture.
// No production audio/process/pkgutil adapter is called by this executable.
private var checks = 0
private func expect(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); expect(false, message) } catch { expect(true, message) }
}

private final class Fixture {
    let root: String
    private var aclPaths: [String] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenRemote-uninstall-test-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try directory("/Applications", mode: 0o775)
        try directory("/Library/Audio/Plug-Ins/HAL")
        try directory("/Library/PrivilegedHelperTools")
        try directory("/Users/test/Library/Application Support/OpenRemoteAssistant")
        try write("/Users/test/Library/Application Support/OpenRemoteAssistant/sentinel", text: "personal data")
    }
    deinit {
        for path in aclPaths { _ = try? command("/bin/chmod", ["-N", path]) }
        try? FileManager.default.removeItem(atPath: root)
    }
    func path(_ relative: String) -> String { root + relative }
    func directory(_ relative: String, mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode])
        guard chmod(path(relative), mode_t(mode)) == 0 else { throw UninstallFailure("fixture chmod failed") }
    }
    func write(_ relative: String, text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path(relative)))
        guard chmod(path(relative), 0o644) == 0 else { throw UninstallFailure("fixture chmod failed") }
    }
    func bundle(_ target: UninstallTarget, identifier: String? = nil) throws {
        try directory(target.path + "/Contents/MacOS")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier ?? target.bundleID], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path(target.path + "/Contents/Info.plist")))
        guard chmod(path(target.path + "/Contents/Info.plist"), 0o644) == 0 else { throw UninstallFailure("fixture chmod failed") }
        try write(target.path + "/Contents/MacOS/fixture", text: "not an executable")
        if target == .application {
            try directory(target.path + "/Contents/Helpers")
            try write(target.path + "/Contents/Helpers/OpenRemoteUninstallHelper", text: "inert helper fixture")
            let embedded = target.path + "/Contents/Helpers/OpenRemoteHIDCoreService.app"
            try directory(embedded + "/Contents/MacOS")
            let embeddedPlist = try PropertyListSerialization.data(fromPropertyList:
                ["CFBundleIdentifier": UninstallTarget.hidService.bundleID], format: .xml, options: 0)
            try embeddedPlist.write(to: URL(fileURLWithPath: path(embedded + "/Contents/Info.plist")))
            guard chmod(path(embedded + "/Contents/Info.plist"), 0o644) == 0 else { throw UninstallFailure("fixture chmod failed") }
            try write(embedded + "/Contents/MacOS/OpenRemoteHIDCoreService", text: "inert embedded service fixture")
        }
    }
    func exists(_ target: UninstallTarget) -> Bool { FileManager.default.fileExists(atPath: path(target.path)) }
    func filesystem(beforeMove: ((UninstallTarget) throws -> Void)? = nil,
                    beforeUnlink: ((UninstallTarget, String) throws -> Void)? = nil) -> SafeUninstallFileSystem {
        SafeUninstallFileSystem(rootPath: root, expectedOwner: getuid(), applicationsGroup: getgid(),
            beforeMove: beforeMove, beforeUnlink: beforeUnlink)
    }
    func stages() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path("/Library/Audio/Plug-Ins/HAL"))
            .filter { $0.hasPrefix(".OpenRemoteUninstall-") }
    }
    func setACL(_ relative: String, _ rule: String) throws {
        let target = path(relative)
        guard try command("/bin/chmod", ["+a", rule, target]) == 0 else { throw UninstallFailure("fixture ACL setup failed") }
        aclPaths.append(target)
    }
    func assertPersonalData() throws {
        expect(try String(contentsOfFile: path("/Users/test/Library/Application Support/OpenRemoteAssistant/sentinel"), encoding: .utf8) == "personal data", "personal data unchanged")
    }
}

@discardableResult private func command(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}

private final class FakeAudio: UninstallAudioChecking {
    var calls = 0
    var failAt: Int?
    func checkSafe() throws { calls += 1; if calls == failAt { throw UninstallFailure("fake audio busy or unavailable") } }
}
private final class FakeProcesses: UninstallProcessChecking {
    var calls = 0
    var failAt: Int?
    func checkStopped() throws { calls += 1; if calls == failAt { throw UninstallFailure("fake main application running") } }
}
private final class FakeReceipts: UninstallReceiptManaging {
    var values = UninstallCoordinator.receiptIDs
    var queries = 0
    var forgotten: [String] = []
    var failQueryAt: Int?
    var failForgetAt: Int?
    var retainAfterForget = false
    func installed() throws -> Set<String> {
        queries += 1
        if queries == failQueryAt { throw UninstallFailure("fake receipt query failure") }
        return values
    }
    func forget(_ identifier: String) throws {
        forgotten.append(identifier)
        if forgotten.count == failForgetAt { throw UninstallFailure("fake forget failure") }
        if !retainAfterForget { values.remove(identifier) }
    }
}
private final class FakeCommandRunner: UninstallCommandRunning {
    var calls: [[String]] = []
    var responses: [UninstallCommandResult] = []
    func run(arguments: [String]) throws -> UninstallCommandResult {
        calls.append(arguments)
        guard !responses.isEmpty else { throw UninstallFailure("unexpected fake command") }
        return responses.removeFirst()
    }
}

private final class FakeAudioMetadata: UninstallAudioMetadataReading {
    var defaults: [AudioObjectPropertySelector: UInt32] = [kAudioHardwarePropertyDefaultInputDevice: 100,
        kAudioHardwarePropertyDefaultOutputDevice: 100, kAudioHardwarePropertyDefaultSystemOutputDevice: 100]
    var uids: [AudioDeviceID: String] = [100: "other-device", 200: "OpenRemoteAudio_UID", 201: "OpenRemoteAudio_2_UID"]
    var translations: [String: AudioDeviceID] = ["OpenRemoteAudio_UID": 200, "OpenRemoteAudio_2_UID": 201]
    var running: [AudioDeviceID: UInt32] = [200: 0, 201: 0]
    var queriedUIDs: [String] = []
    var fail = false
    func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        if fail { throw UninstallFailure("fake unavailable audio metadata") }
        if id == kAudioObjectSystemObject, let value = defaults[selector] { return value }
        if selector == kAudioDevicePropertyDeviceIsRunningSomewhere, let value = running[id] { return value }
        throw UninstallFailure("unexpected audio property")
    }
    func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        guard selector == kAudioDevicePropertyDeviceUID, let value = uids[id] else { throw UninstallFailure("unknown fake audio UID") }
        return value
    }
    func translate(_ text: String) throws -> AudioDeviceID {
        queriedUIDs.append(text)
        guard let value = translations[text] else { throw UninstallFailure("translation failure") }
        return value
    }
}

@main struct UninstallerTests {
    static func main() throws {
        try happyPathAndPreflight()
        try guardsAndPartialFailures()
        try unsafeFiles()
        try hidServiceTargetCases()
        try actualRenameRaces()
        try aclCases()
        try receiptAdapterCases()
        try audioPolicyCases()
        print("Uninstaller tests passed: \(checks) checks (isolated fixtures; no installed components/audio/processes/receipts touched).")
    }

    private static func coordinator(_ files: UninstallFileManaging, _ audio: FakeAudio = FakeAudio(),
                            _ processes: FakeProcesses = FakeProcesses(), _ receipts: FakeReceipts = FakeReceipts()) -> UninstallCoordinator {
        UninstallCoordinator(files: files, audio: audio, processes: processes, receipts: receipts)
    }

    static func happyPathAndPreflight() throws {
        do {
            let fixture = try Fixture()
            try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            let files = fixture.filesystem(), receipts = FakeReceipts(), audio = FakeAudio(), processes = FakeProcesses()
            let report = coordinator(files, audio, processes, receipts).run(mode: .preflight, effectiveUID: getuid())
            expect(report.success, "normal root-equivalent owned trees and Applications 0775 pass preflight: \(report.message)")
            expect(!report.restartRequired && !files.mutationOccurred, "preflight is read-only")
            expect(UninstallTarget.allCases.allSatisfy(fixture.exists), "preflight preserves all three targets")
            expect(receipts.forgotten.isEmpty && receipts.queries == 1, "preflight never forgets receipts")
            expect(try fixture.stages().isEmpty, "preflight never creates quarantine")
            try fixture.assertPersonalData()
        }
        do {
            let fixture = try Fixture()
            try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            var order: [UninstallTarget] = []
            let files = fixture.filesystem(beforeMove: { order.append($0) }), receipts = FakeReceipts()
            let report = coordinator(files, FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(report.success, "valid fixture uninstall succeeds: \(report.message)")
            expect(report.restartRequired && !report.possiblePartialCompletion, "success requires restart")
            expect(order == [.driver, .hidService, .application], "driver and installed key service removed before application")
            expect(UninstallTarget.allCases.allSatisfy { !fixture.exists($0) }, "all three fixed targets absent")
            expect(report.removedTargets == [UninstallTarget.driver.path, UninstallTarget.hidService.path,
                                              UninstallTarget.application.path], "removed paths explicit")
            expect(receipts.values.isEmpty && receipts.queries == 2, "exact receipts removed and read back")
            expect(try report.recoveryPaths.isEmpty && files.recoveryPaths.isEmpty && fixture.stages().isEmpty, "successful quarantine cleanup")
            try fixture.assertPersonalData()
        }
        do {
            let fixture = try Fixture(), receipts = FakeReceipts()
            receipts.values = []
            let report = coordinator(fixture.filesystem(), FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(report.success && !report.restartRequired, "already absent is idempotent")
            expect(report.alreadyAbsentTargets.count == 3, "all absent components reported")
            expect(try fixture.stages().isEmpty, "absent components do not create quarantine")
        }
    }

    static func guardsAndPartialFailures() throws {
        do {
            let fixture = try Fixture(), audio = FakeAudio(), processes = FakeProcesses(), receipts = FakeReceipts()
            let files = fixture.filesystem()
            let report = coordinator(files, audio, processes, receipts).run(mode: .uninstall, effectiveUID: 501)
            expect(!report.success && !report.possiblePartialCompletion, "uninstall rejects non-root before work")
            expect(audio.calls == 0 && processes.calls == 0 && receipts.queries == 0, "non-root guard has no adapter effects")
        }
        for failure in ["audio", "process", "receipt"] {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            let audio = FakeAudio(), processes = FakeProcesses(), receipts = FakeReceipts()
            if failure == "audio" { audio.failAt = 1 }
            if failure == "process" { processes.failAt = 1 }
            if failure == "receipt" { receipts.failQueryAt = 1 }
            let report = coordinator(fixture.filesystem(), audio, processes, receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && !report.possiblePartialCompletion, "\(failure) preflight failure prevents deletion")
            expect(UninstallTarget.allCases.allSatisfy(fixture.exists), "\(failure) failure preserves all components")
            expect(receipts.forgotten.isEmpty, "\(failure) failure preserves receipts")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            let audio = FakeAudio(), receipts = FakeReceipts(); audio.failAt = 3
            let files = fixture.filesystem()
            let report = coordinator(files, audio, FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && report.possiblePartialCompletion && report.restartRequired, "late audio busy reports partial completion")
            expect(!fixture.exists(.driver) && fixture.exists(.hidService) && fixture.exists(.application),
                   "late busy stops before deleting key service or app")
            expect(receipts.forgotten.isEmpty, "partial file failure preserves receipt evidence")
            expect(try files.recoveryPaths.isEmpty && fixture.stages().isEmpty, "failure cleans empty quarantine")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            var unlinks = 0
            let files = fixture.filesystem(beforeUnlink: { _, _ in
                unlinks += 1
                if unlinks == 2 { throw UninstallFailure("injected unlink failure after first deletion") }
            })
            let receipts = FakeReceipts()
            let report = coordinator(files, FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && report.possiblePartialCompletion, "mid-tree failure reported")
            expect(!fixture.exists(.driver) && fixture.exists(.application), "damaged driver retained in stage, app unchanged")
            expect(report.recoveryPaths.count == 1 && FileManager.default.fileExists(atPath: report.recoveryPaths[0]), "partial failure includes existing recovery path")
            expect(report.message.contains(report.recoveryPaths.first ?? "impossible"), "message itself displays recovery path")
            expect(receipts.forgotten.isEmpty, "mid-tree failure does not forget receipts")
            let retryReceipts = FakeReceipts(), retryFiles = fixture.filesystem()
            let retry = coordinator(retryFiles, FakeAudio(), FakeProcesses(), retryReceipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!retry.success && !retryFiles.mutationOccurred, "retry never ignores an existing failed quarantine")
            expect(retry.possiblePartialCompletion && retry.restartRequired, "prior quarantine makes incomplete state explicit")
            expect(fixture.exists(.application) && retryReceipts.forgotten.isEmpty, "existing quarantine stops before other app or receipts removed")
            expect(retry.recoveryPaths.count == 1 && retry.message.contains(retry.recoveryPaths[0]), "retry displays prior quarantine path")
        }
        for variant in ["forget", "readback", "stale"] {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            let receipts = FakeReceipts()
            if variant == "forget" { receipts.failForgetAt = 1 }
            if variant == "readback" { receipts.failQueryAt = 2 }
            if variant == "stale" { receipts.retainAfterForget = true }
            let report = coordinator(fixture.filesystem(), FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && report.possiblePartialCompletion && report.restartRequired, "\(variant) receipt failure is not success")
            expect(UninstallTarget.allCases.allSatisfy { !fixture.exists($0) },
                   "\(variant) identifies all removed files despite receipt failure")
            expect(report.phase == "receipts", "\(variant) receipt phase reported")
        }
        do {
            let fixture = try Fixture(), receipts = FakeReceipts(); receipts.failForgetAt = 1
            let report = coordinator(fixture.filesystem(), FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && report.possiblePartialCompletion, "failed receipt mutation attempt is conservatively partial even with absent files")
        }
    }

    static func unsafeFiles() throws {
        for scenario in ["parent-link", "target-link", "nested-link", "plist-link", "hard-link", "fifo", "wrong-id", "group-writable", "parent-writable", "root-writable", "wrong-owner"] {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.hidService); try fixture.bundle(.application)
            let app = fixture.path(UninstallTarget.application.path)
            let binary = app + "/Contents/MacOS/fixture"
            let outside = fixture.path("/outside-sentinel")
            try fixture.write("/outside-sentinel", text: "outside must survive")
            switch scenario {
            case "parent-link":
                try FileManager.default.moveItem(atPath: fixture.path("/Applications"), toPath: fixture.path("/ActualApplications"))
                expect(symlink(fixture.path("/ActualApplications"), fixture.path("/Applications")) == 0, "set parent symlink fixture")
            case "target-link":
                try FileManager.default.moveItem(atPath: app, toPath: fixture.path("/actual-app"))
                expect(symlink(fixture.path("/actual-app"), app) == 0, "set target symlink fixture")
            case "nested-link": expect(symlink(outside, app + "/Contents/link") == 0, "set nested symlink fixture")
            case "plist-link":
                let plist = app + "/Contents/Info.plist"
                try FileManager.default.moveItem(atPath: plist, toPath: fixture.path("/actual-plist"))
                expect(symlink(fixture.path("/actual-plist"), plist) == 0, "set Info.plist symlink fixture")
            case "hard-link": expect(link(outside, app + "/Contents/hardlink") == 0, "set hard link fixture")
            case "fifo": expect(mkfifo(app + "/Contents/pipe", 0o600) == 0, "set FIFO fixture")
            case "wrong-id": try fixture.bundle(.application, identifier: "other.vendor.app")
            case "group-writable": expect(chmod(binary, 0o664) == 0, "set writable file fixture")
            case "parent-writable": expect(chmod(fixture.path("/Library/Audio/Plug-Ins/HAL"), 0o775) == 0, "set unsafe parent fixture")
            case "root-writable": expect(chmod(fixture.root, 0o777) == 0, "set unsafe root fixture")
            default: break
            }
            let files = scenario == "wrong-owner"
                ? SafeUninstallFileSystem(rootPath: fixture.root, expectedOwner: getuid() + 1, applicationsGroup: getgid())
                : fixture.filesystem()
            let receipts = FakeReceipts()
            let report = coordinator(files, FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && !files.mutationOccurred, "\(scenario) rejected before any target mutation")
            expect(fixture.exists(.driver), "\(scenario) validates app before deleting driver")
            expect(try String(contentsOfFile: outside, encoding: .utf8) == "outside must survive", "\(scenario) does not follow outside file")
            expect(receipts.forgotten.isEmpty, "\(scenario) does not remove receipts")
        }
    }

    static func hidServiceTargetCases() throws {
        do {
            let fixture = try Fixture()
            try fixture.bundle(.driver); try fixture.bundle(.hidService, identifier: "other.vendor.service"); try fixture.bundle(.application)
            let files = fixture.filesystem(), receipts = FakeReceipts()
            let report = coordinator(files, FakeAudio(), FakeProcesses(), receipts).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && !files.mutationOccurred, "wrong installed key-service identity blocks every deletion")
            expect(UninstallTarget.allCases.allSatisfy(fixture.exists), "identity failure preserves app, driver and service")
            expect(receipts.forgotten.isEmpty, "identity failure preserves receipts")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.hidService)
            let service = fixture.path(UninstallTarget.hidService.path)
            try FileManager.default.moveItem(atPath: service, toPath: fixture.path("/actual-hid-service"))
            expect(symlink(fixture.path("/actual-hid-service"), service) == 0, "set installed service symlink fixture")
            let files = fixture.filesystem()
            let report = coordinator(files).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && !files.mutationOccurred, "installed key-service symlink rejected before quarantine")
            expect(FileManager.default.fileExists(atPath: fixture.path("/actual-hid-service/Contents/Info.plist")),
                   "service symlink target remains untouched")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.hidService)
            let parent = fixture.path("/Library/PrivilegedHelperTools")
            try FileManager.default.moveItem(atPath: parent, toPath: fixture.path("/actual-privileged-helper-tools"))
            expect(symlink(fixture.path("/actual-privileged-helper-tools"), parent) == 0,
                   "set key-service parent symlink fixture")
            let files = fixture.filesystem()
            let report = coordinator(files).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && !files.mutationOccurred, "key-service parent symlink rejected")
            expect(FileManager.default.fileExists(atPath: fixture.path("/actual-privileged-helper-tools/"
                + UninstallTarget.hidService.leaf + "/Contents/Info.plist")), "parent symlink contents untouched")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.driver); try fixture.bundle(.application)
            let report = coordinator(fixture.filesystem()).run(mode: .uninstall, effectiveUID: 0)
            expect(report.success, "missing installed service is an explicit idempotent absence")
            expect(report.alreadyAbsentTargets == [UninstallTarget.hidService.path], "only missing service reported absent")
            expect(!fixture.exists(.driver) && !fixture.exists(.application), "remaining owned targets removed")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.hidService)
            let service = fixture.path(UninstallTarget.hidService.path)
            let files = fixture.filesystem(beforeMove: { target in
                guard target == .hidService else { return }
                try FileManager.default.moveItem(atPath: service, toPath: fixture.path("/original-hid-service"))
                try FileManager.default.createDirectory(atPath: service, withIntermediateDirectories: false)
                try Data("replacement service must survive".utf8).write(to: URL(fileURLWithPath: service + "/sentinel"))
            })
            let report = coordinator(files).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success, "installed service swap across final check and rename rejected")
            expect(try String(contentsOfFile: service + "/sentinel", encoding: .utf8) == "replacement service must survive",
                   "replacement service restored without deletion")
            expect(FileManager.default.fileExists(atPath: fixture.path("/original-hid-service/Contents/Info.plist")),
                   "original swapped service remains untouched")
        }
    }

    static func actualRenameRaces() throws {
        do {
            let fixture = try Fixture(); try fixture.bundle(.application)
            let app = fixture.path(UninstallTarget.application.path)
            let files = fixture.filesystem(beforeMove: { _ in
                try FileManager.default.moveItem(atPath: app, toPath: fixture.path("/original-app"))
                try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
                try Data("replacement must survive".utf8).write(to: URL(fileURLWithPath: app + "/sentinel"))
            })
            let report = coordinator(files).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success, "target swap across final check and rename rejected")
            expect(try String(contentsOfFile: app + "/sentinel", encoding: .utf8) == "replacement must survive", "replacement safely restored without deletion")
            expect(FileManager.default.fileExists(atPath: fixture.path("/original-app/Contents/Info.plist")), "original swapped-out app untouched")
            expect(try files.recoveryPaths.isEmpty && fixture.stages().isEmpty, "restored race cleans empty stage")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.application)
            let app = fixture.path(UninstallTarget.application.path)
            let files = fixture.filesystem(beforeUnlink: { _, _ in
                try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
                try Data("concurrent reinstall".utf8).write(to: URL(fileURLWithPath: app + "/sentinel"))
                throw UninstallFailure("failure before first unlink with occupied restore destination")
            })
            let report = coordinator(files).run(mode: .uninstall, effectiveUID: 0)
            expect(!report.success && report.possiblePartialCompletion, "occupied restore destination remains a failure")
            expect(try String(contentsOfFile: app + "/sentinel", encoding: .utf8) == "concurrent reinstall", "exclusive restore does not overwrite reinstall")
            expect(report.recoveryPaths.count == 1, "unrestorable original quarantine path reported")
            expect(FileManager.default.fileExists(atPath: report.recoveryPaths[0] + "/Contents/Info.plist"), "unrestored original stays intact")
        }
        do {
            let fixture = try Fixture(); try fixture.bundle(.application)
            let files = fixture.filesystem()
            _ = try files.prepare()
            try fixture.write(UninstallTarget.application.path + "/Contents/new-file", text: "concurrent addition")
            rejects("new entries after preflight cannot be deleted") { try files.remove(.application) }
            expect(fixture.exists(.application) && !files.mutationOccurred, "changed content leaves app in place")
        }
    }

    static func aclCases() throws {
        for (rule, allowed) in [("everyone deny execute", true), ("everyone allow read", false)] {
            let fixture = try Fixture(); try fixture.bundle(.driver)
            try fixture.setACL(UninstallTarget.driver.path + "/Contents/MacOS/fixture", rule)
            let report = coordinator(fixture.filesystem()).run(mode: .preflight, effectiveUID: getuid())
            expect(report.success == allowed, "Darwin ACL \(rule): \(report.message)")
            expect(fixture.exists(.driver), "ACL check read-only")
        }
    }

    static func receiptAdapterCases() throws {
        let identifiers = UninstallCoordinator.receiptIDs.sorted()
        do {
            let runner = FakeCommandRunner()
            runner.responses = [.init(status: 0, output: "other.vendor.pkg\n" + identifiers.joined(separator: "\n") + "\n")]
            let receipts = PkgutilUninstallReceipts(runner: runner)
            expect(try receipts.installed() == Set(identifiers), "exact receipt output parsed")
            expect(runner.calls == [["--pkgs"]], "one fixed receipt listing; only exact own IDs retained")
            runner.responses = [.init(status: 0, output: "Forgot receipt")]
            try receipts.forget(identifiers[0])
            expect(runner.calls.last == ["--forget", identifiers[0]], "only exact forget command")
            let before = runner.calls.count
            rejects("unrelated receipt cannot reach runner") { try receipts.forget("other.product.pkg") }
            expect(runner.calls.count == before, "invalid receipt has no side effect")
        }
        for response in [UninstallCommandResult(status: 1, output: "failure"),
                         .init(status: 1, output: ""),
                         .init(status: 0, output: identifiers[0] + "\n" + identifiers[0] + "\n"),
                         .init(status: 0, output: String(repeating: "x", count: 1_048_577))] {
            let runner = FakeCommandRunner(); runner.responses = [response]
            rejects("bad receipt query rejected") { _ = try PkgutilUninstallReceipts(runner: runner).installed() }
        }
        for output in ["", "other.product.pkg\n", "org.rc001remote.assistant.pkg.neighbor\n"] {
            let runner = FakeCommandRunner(); runner.responses = [.init(status: 0, output: output)]
            expect(try PkgutilUninstallReceipts(runner: runner).installed().isEmpty, "absent own receipts are safe; unrelated IDs never retained")
        }
        do {
            let runner = FakeCommandRunner(); runner.responses = [.init(status: 1, output: "failed")]
            rejects("nonzero pkgutil forget is not ignored") { try PkgutilUninstallReceipts(runner: runner).forget(identifiers[0]) }
        }
        do {
            // Validation occurs before PkgutilCommandRunner checks or launches
            // the real executable; these invalid argument cases are offline.
            let runner = PkgutilCommandRunner()
            rejects("production runner rejects runtime query patterns") { _ = try runner.run(arguments: ["--pkgs=.*"]) }
            rejects("production runner rejects arbitrary executable args") { _ = try runner.run(arguments: ["--forget", "other.pkg"]) }
        }
    }

    static func audioPolicyCases() throws {
        do {
            let metadata = FakeAudioMetadata()
            try CoreAudioUninstallChecks(metadata: metadata).checkSafe()
            expect(metadata.queriedUIDs == ["OpenRemoteAudio_UID", "OpenRemoteAudio_2_UID"], "audio guard translates both visible and hidden endpoint UIDs")
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            for ownedID in [AudioDeviceID(200), 201] {
                let metadata = FakeAudioMetadata(); metadata.defaults[selector] = ownedID
                rejects("either own endpoint as any default prevents uninstall") { try CoreAudioUninstallChecks(metadata: metadata).checkSafe() }
            }
        }
        for ownedID in [AudioDeviceID(200), 201] {
            let metadata = FakeAudioMetadata(); metadata.running[ownedID] = 1
            rejects("either owned endpoint busy prevents uninstall") { try CoreAudioUninstallChecks(metadata: metadata).checkSafe() }
        }
        do {
            let metadata = FakeAudioMetadata(); metadata.fail = true
            rejects("audio metadata error is fail closed") { try CoreAudioUninstallChecks(metadata: metadata).checkSafe() }
        }
        do {
            let metadata = FakeAudioMetadata(); metadata.translations["OpenRemoteAudio_2_UID"] = 100
            rejects("hidden endpoint UID mismatch prevents uninstall") { try CoreAudioUninstallChecks(metadata: metadata).checkSafe() }
        }
        do {
            let metadata = FakeAudioMetadata(); metadata.translations["OpenRemoteAudio_2_UID"] = nil
            rejects("hidden endpoint query failure is not treated as absence") { try CoreAudioUninstallChecks(metadata: metadata).checkSafe() }
        }
        do {
            let metadata = FakeAudioMetadata()
            metadata.translations = ["OpenRemoteAudio_UID": kAudioObjectUnknown, "OpenRemoteAudio_2_UID": kAudioObjectUnknown]
            try CoreAudioUninstallChecks(metadata: metadata).checkSafe()
            expect(metadata.queriedUIDs.count == 2, "both already absent endpoints are safe")
        }
    }
}
