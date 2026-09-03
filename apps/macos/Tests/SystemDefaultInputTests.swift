import Foundation
import CoreAudio

private struct FakeInput {
    let uid: String
    let name: String
    var usable: Bool = true
}

private final class FakeDefaultInputAccess: SystemDefaultInputAccess {
    var inputs: [AudioDeviceID: FakeInput] = [
        10: FakeInput(uid: "previous-input", name: "原麦克风"),
        89: FakeInput(uid: VoiceAudioCatalog.inputUID, name: VoiceAudioCatalog.inputName)
    ]
    var current: AudioDeviceID? = 10
    var remote: VoiceAudioDevice? = VoiceAudioDevice(uid: VoiceAudioCatalog.inputUID,
        name: VoiceAudioCatalog.inputName, deviceID: 89)
    var mutationResult: SystemDefaultInputMutationResult = .confirmed
    var applySet = true
    var defaultReads: [AudioDeviceID?] = []
    var setCalls: [AudioDeviceID] = []

    func validatedRemoteInput() -> VoiceAudioDevice? { remote }
    func defaultInputID() -> AudioDeviceID? {
        if !defaultReads.isEmpty { return defaultReads.removeFirst() }
        return current
    }
    func uid(for device: AudioDeviceID) -> String? { inputs[device]?.uid }
    func name(for device: AudioDeviceID) -> String? { inputs[device]?.name }
    func translate(uid: String) -> AudioDeviceID? { inputs.first(where: { $0.value.uid == uid })?.key }
    func isUsableInput(_ device: AudioDeviceID) -> Bool { inputs[device]?.usable == true }
    func setDefaultInputAndWait(_ device: AudioDeviceID) -> SystemDefaultInputMutationResult {
        setCalls.append(device)
        if mutationResult == .confirmed, applySet { current = device }
        return mutationResult
    }
}

private final class FakePreviousInputStore: PreviousDefaultInputStoring {
    var previousDefaultInputUID: String?
    init(_ value: String? = nil) { previousDefaultInputUID = value }
}

@main
struct SystemDefaultInputTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore()
            let controller = SystemDefaultInputController(access: access, storage: store)
            let before = controller.snapshot()
            expect(before.currentName == "原麦克风", "snapshot names current input")
            expect(!before.remoteIsDefault && before.canSelectRemote, "remote can be selected explicitly")
            let after = try controller.selectRemoteInput()
            expect(access.setCalls == [89], "selection writes only the validated remote input")
            expect(store.previousDefaultInputUID == "previous-input", "selection stores previous UID")
            expect(after.remoteIsDefault && after.canRestorePrevious, "successful readback enables restoration")
            expect(after.previousName == "原麦克风", "restoration identifies previous device")
        } catch { fputs("FAIL: unexpected selection error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore()
            access.mutationResult = .failed(-50)
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.selectRemoteInput(); expect(false, "failed write must throw") }
            catch { expect(error as? SystemDefaultInputError == .setFailed(-50), "write error is preserved") }
            expect(store.previousDefaultInputUID == nil, "failed write clears unused recovery UID")
            expect(access.current == 10, "failed write leaves default unchanged")
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore()
            access.applySet = false
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.selectRemoteInput(); expect(false, "failed readback must throw") }
            catch { expect(error as? SystemDefaultInputError == .verificationFailed, "readback failure is explicit") }
            expect(store.previousDefaultInputUID == nil, "unverified selection clears recovery ownership")
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore()
            access.mutationResult = .confirmationTimedOut
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.selectRemoteInput(); expect(false, "unconfirmed asynchronous write must throw") }
            catch { expect(error as? SystemDefaultInputError == .confirmationTimedOut,
                           "missing Core Audio notification stays unconfirmed") }
            expect(store.previousDefaultInputUID == nil,
                   "unconfirmed write discards recovery ownership and requires manual review")
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = 89
            let controller = SystemDefaultInputController(access: access, storage: store)
            let result = try controller.restorePreviousInput()
            expect(result == .restored("原麦克风"), "validated explicit restoration succeeds")
            expect(access.setCalls == [10] && access.current == 10, "restoration targets previous input")
            expect(store.previousDefaultInputUID == nil, "successful restoration clears recovery UID")
        } catch { fputs("FAIL: unexpected restore error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = 22
            access.inputs[22] = FakeInput(uid: "user-new-input", name: "用户新选择")
            let controller = SystemDefaultInputController(access: access, storage: store)
            let result = try controller.restorePreviousInput()
            expect(result == .currentChanged("用户新选择"), "external default change is reported")
            expect(access.setCalls.isEmpty, "external default change is never overwritten")
            expect(store.previousDefaultInputUID == nil, "external change clears stale recovery ownership")
            access.current = 89
            let later = try controller.restorePreviousInput()
            expect(later == .nothingToRestore,
                   "later return to remote cannot revive a stale recovery UID")
        } catch { fputs("FAIL: unexpected changed-default error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = 89
            access.defaultReads = [89, 22, 22]
            access.inputs[22] = FakeInput(uid: "raced-input", name: "并发新输入")
            let controller = SystemDefaultInputController(access: access, storage: store)
            let result = try controller.restorePreviousInput()
            expect(result == .currentChanged("并发新输入"), "last pre-write read catches an earlier external change")
            expect(access.setCalls.isEmpty, "observed external change is not overwritten")
            expect(store.previousDefaultInputUID == nil, "observed external change clears recovery ownership")
        } catch { fputs("FAIL: unexpected race error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = 89
            access.inputs[10]?.usable = false
            let controller = SystemDefaultInputController(access: access, storage: store)
            let result = try controller.restorePreviousInput()
            expect(result == .previousUnavailable,
                   "disconnected previous input is not selected")
            expect(access.setCalls.isEmpty, "unavailable previous device causes no mutation")
        } catch { fputs("FAIL: unexpected unavailable error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore()
            access.remote = nil
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.selectRemoteInput(); expect(false, "unvalidated remote must fail") }
            catch { expect(error as? SystemDefaultInputError == .remoteUnavailable, "remote identity fails closed") }
            expect(access.setCalls.isEmpty, "invalid remote causes no default mutation")
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.remote = nil
            access.current = 89
            let controller = SystemDefaultInputController(access: access, storage: store)
            let snapshot = controller.snapshot()
            expect(snapshot.remoteIsDefault && snapshot.canRestorePrevious,
                   "restore remains available when the hidden route or provider catalog is damaged")
            let restored = try controller.restorePreviousInput()
            expect(restored == .restored("原麦克风"),
                   "restore does not depend on selecting catalog validation")
        } catch { fputs("FAIL: unexpected damaged-catalog restore error \(error)\n", stderr); exit(1) }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = nil
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.restorePreviousInput(); expect(false, "missing current input must throw") }
            catch { expect(error as? SystemDefaultInputError == .currentUnavailable,
                           "missing current input is not treated as an external choice") }
            expect(store.previousDefaultInputUID == "previous-input",
                   "read failure does not destroy recovery evidence")
        }

        do {
            let access = FakeDefaultInputAccess(), store = FakePreviousInputStore("previous-input")
            access.current = 89
            access.defaultReads = [89, nil]
            let controller = SystemDefaultInputController(access: access, storage: store)
            do { _ = try controller.restorePreviousInput(); expect(false, "failed last read must throw") }
            catch { expect(error as? SystemDefaultInputError == .currentUnavailable,
                           "last-read failure is not reported as a changed default") }
            expect(access.setCalls.isEmpty && store.previousDefaultInputUID == "previous-input",
                   "failed last read causes no mutation and preserves recovery evidence")
        }

        let suite = "SystemDefaultInputTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
        let persistent = UserDefaultsPreviousDefaultInputStore(defaults: defaults, key: "previous")
        persistent.previousDefaultInputUID = "fixture-input"
        expect(persistent.previousDefaultInputUID == "fixture-input", "recovery UID persists locally")
        persistent.previousDefaultInputUID = String(repeating: "x", count: 1_025)
        expect(persistent.previousDefaultInputUID == nil, "oversized recovery UID is rejected")
        defaults.removePersistentDomain(forName: suite)

        print("SystemDefaultInputTests: \(checks) checks passed; fake CoreAudio access and isolated defaults only.")
    }
}
