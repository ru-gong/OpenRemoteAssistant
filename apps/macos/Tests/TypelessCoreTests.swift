// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 SayAll contributors
// Modifications Copyright (C) 2026 OpenRemoteAssistant contributors
// Modified 2026-09-02.
// Adapted from HD838A/remote-mic-app tests at commit
// 9e019112fc88534004641499b0b1efc50b491e5e.
// Pure policy tests: no HID service is enumerated or modified, no key is posted,
// and no audio device is opened.

import Foundation
import CoreGraphics

@main
enum TypelessCoreTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAILED: \(label)") }
            checks += 1
        }

        testMapper(check: check)
        testSessionLifecycle(check: check)
        testHoldLifecycle(check: check)
        print("Typeless core: \(checks) checks passed; no hardware opened, system mappings written, keys posted, or audio streamed.")
    }

    private static func testMapper(
        check: (_ condition: @autoclosure () -> Bool, _ label: String) -> Void
    ) {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let staleVoice = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let stalePower = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source,
            destination: 0x0000_0007_0000_006E
        )

        check(RemoteVoiceFunctionMappingPolicy.remoteVoiceKey == HIDUsageMapping(
            source: 0x0000_0007_0000_003E,
            destination: 0x0000_00FF_0000_0003
        ), "RC003 F5 default maps to Apple Fn/Globe")
        check(RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey == HIDUsageMapping(
            source: 0x0000_0007_0000_003E,
            destination: 0
        ), "Typeless mode neutralizes the physical F5 transactionally")
        check(RemoteVoiceFunctionMappingPolicy.applying(
            to: [unrelated, staleVoice, stalePower],
            voiceMapping: RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
        ) == [unrelated, RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey],
        "policy replaces only owned F5 and power sources")
        check(HIDUsageMapping(
            property: RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey.property
        ) == RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
        "mapping property round trips")

        let first = MappingServiceBox(registryID: 1, mappings: [unrelated])
        let second = MappingServiceBox(
            registryID: 2,
            mappings: [unrelated],
            acceptsWrites: false
        )
        let rollbackMapper = RemoteVoiceFunctionMapper { [first.service, second.service] }
        check(!rollbackMapper.apply(neutralizeVoiceKey: true),
              "partial neutralization fails the whole transaction")
        check(!rollbackMapper.isApplied && !rollbackMapper.isVoiceKeyNeutralized,
              "failed transaction never reports neutralized")
        check(first.mappings == [unrelated], "partial success rolls back to its snapshot")
        check(first.writeCount == 2 && second.writeCount == 1,
              "successful target is rolled back exactly once after peer failure")

        let missingIdentity = MappingServiceBox(registryID: nil, mappings: [])
        let incompleteMapper = RemoteVoiceFunctionMapper { [missingIdentity.service] }
        check(!incompleteMapper.apply(neutralizeVoiceKey: true),
              "an incomplete target fails closed")
        check(incompleteMapper.hasMatchingServices && missingIdentity.writeCount == 0,
              "incomplete target is counted but never written")

        let originalVoice = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let successful = MappingServiceBox(
            registryID: 9,
            mappings: [unrelated, originalVoice]
        )
        let successfulMapper = RemoteVoiceFunctionMapper { [successful.service] }
        check(successfulMapper.apply(neutralizeVoiceKey: true),
              "complete target neutralization succeeds")
        check(successfulMapper.isApplied && successfulMapper.isVoiceKeyNeutralized,
              "complete transaction reports neutralized")
        check(successful.mappings == [
            unrelated,
            RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
        ], "successful transaction writes usage zero only for RC003 F5")
        let changedUnrelated = HIDUsageMapping(
            source: unrelated.source,
            destination: 0x0000_0007_0000_0006
        )
        successful.mappings = [
            changedUnrelated,
            RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
        ]
        successfulMapper.restore()
        check(successful.mappings == [changedUnrelated, originalVoice],
              "mapper restore returns original F5 and preserves unrelated live changes")
        check(!successfulMapper.isApplied && !successfulMapper.isVoiceKeyNeutralized,
              "restore clears applied state")

        let emptyMapper = RemoteVoiceFunctionMapper { [] }
        check(!emptyMapper.apply(neutralizeVoiceKey: true),
              "no matching service cannot claim success")
        check(!emptyMapper.hasMatchingServices && emptyMapper.matchedServiceCount == 0,
              "no-target result is distinguishable from target write failure")

        var recoverableMappings = [unrelated]
        var firstWriteResults = [true, false, true]
        let recoverable = RemoteVoiceMappingService(
            registryID: 10,
            readMappings: { recoverableMappings },
            setMappings: { mappings in
                guard !firstWriteResults.isEmpty, firstWriteResults.removeFirst() else {
                    return false
                }
                recoverableMappings = mappings
                return true
            }
        )
        let peerFailure = MappingServiceBox(
            registryID: 11,
            mappings: [unrelated],
            acceptsWrites: false
        )
        let recoverableMapper = RemoteVoiceFunctionMapper {
            [recoverable, peerFailure.service]
        }
        check(!recoverableMapper.apply(neutralizeVoiceKey: true),
              "rollback-write failure still reports transaction failure")
        check(recoverableMappings == [
            unrelated,
            RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
        ], "failed rollback leaves the actual mapping observable")
        recoverableMapper.restore()
        check(recoverableMappings == [unrelated],
              "failed rollback retains original state for a later restore")

        let restoreFailure = MappingServiceBox(
            registryID: 12,
            mappings: [unrelated, originalVoice]
        )
        let restoreRetryMapper = RemoteVoiceFunctionMapper { [restoreFailure.service] }
        check(restoreRetryMapper.apply(neutralizeVoiceKey: true),
              "restore retry fixture first applies the owned mapping")
        restoreFailure.acceptsWrites = false
        check(!restoreRetryMapper.restore() && restoreRetryMapper.hasPendingRestoration,
              "failed restore retains the original snapshot and reports pending")
        check(restoreFailure.mappings.last == RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
              "failed restore does not claim that the live neutral mapping changed")
        restoreFailure.acceptsWrites = true
        check(restoreRetryMapper.restore() && !restoreRetryMapper.hasPendingRestoration,
              "later restore retry consumes the retained snapshot only after success")
        check(restoreFailure.mappings == [unrelated, originalVoice],
              "later restore retry returns the exact original owned mapping")

        check(RemoteVoiceFunctionMappingPolicy.restoring(
            originalVoiceMapping: originalVoice,
            originalPowerMapping: stalePower,
            in: [
                changedUnrelated,
                RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
                RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey,
            ]
        ) == [changedUnrelated, originalVoice, stalePower],
        "restore preserves unrelated mappings changed while active")

        let boundFirst = MappingServiceBox(registryID: 20, locationID: 900, mappings: [unrelated])
        let boundSecond = MappingServiceBox(registryID: 21, locationID: 900, mappings: [unrelated])
        let otherRemote = MappingServiceBox(registryID: 22, locationID: 901, mappings: [unrelated])
        let boundMapper = RemoteVoiceFunctionMapper {
            [boundFirst.service, boundSecond.service, otherRemote.service]
        }
        check(boundMapper.apply(neutralizeVoiceKey: true, targetLocationID: 900),
              "bound location neutralization succeeds across all of its services")
        check(boundMapper.matchedServiceCount == 2,
              "bound location counts every matching service at that location")
        check(boundFirst.mappings.last == RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey &&
              boundSecond.mappings.last == RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
              "all services at the bound location receive usage zero")
        check(otherRemote.mappings == [unrelated] && otherRemote.writeCount == 0,
              "a different paired RC003 location is never modified")
        boundMapper.restore()
        check(boundFirst.mappings == [unrelated] && boundSecond.mappings == [unrelated] &&
              otherRemote.mappings == [unrelated],
              "bound restore returns both target services without touching another remote")

        var postedEvents = 0
        check(!TypelessFunctionKeyInjector.setPressed(true,
            accessibilityTrusted: { false },
            eventPoster: { _ in postedEvents += 1 }),
            "Fn injection fails closed without Accessibility")
        check(postedEvents == 0,
              "an untrusted process never posts a synthetic Fn event")

        var posted: [CGEvent] = []
        check(MacFunctionKeyInjector.setPressed(true,
            accessibilityTrusted: { true }, eventPoster: { posted.append($0) }),
            "trusted software Fn down is constructed")
        check(MacFunctionKeyInjector.setPressed(false,
            accessibilityTrusted: { true }, eventPoster: { posted.append($0) }),
            "trusted software Fn up is constructed")
        check(posted.count == 2 && posted[0].type == .flagsChanged && posted[1].type == .flagsChanged,
              "CoreGraphics normalizes software Fn press and release to modifier flags-changed events")
        check(posted.allSatisfy {
            $0.getIntegerValueField(.keyboardEventKeycode) == Int64(MacFunctionKeyInjector.functionKeyCode)
        }, "software Fn always uses macOS virtual key 63")
        check(posted[0].flags.contains(.maskSecondaryFn) && !posted[1].flags.contains(.maskSecondaryFn),
              "software Fn carries the secondary-Fn flag only while pressed")
    }

    private static func testHoldLifecycle(
        check: (_ condition: @autoclosure () -> Bool, _ label: String) -> Void
    ) {
        do {
            let harness = VoiceFnHoldHarness()
            check(!harness.controller.startVoice(), "Fn hold defaults disabled")
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "Fn hold accepts a physical press")
            check(harness.events == [true] && harness.controller.phase == .held(1),
                  "Fn hold posts exactly one down event")
            check(harness.controller.stopVoice(), "Fn hold accepts a physical release")
            check(harness.controller.phase == .draining(1) && harness.events == [true],
                  "Fn remains down until queued tail audio drains")
            harness.completeDrain()
            check(harness.events == [true, false] && harness.controller.phase == .idle,
                  "Fn hold releases exactly once after drain")
        }

        do {
            let harness = VoiceFnHoldHarness(results: [false])
            harness.controller.setEnabled(true)
            check(!harness.controller.startVoice(), "failed Fn down rejects the voice session")
            check(harness.failures == [.holdPressFailed] && harness.controller.phase == .idle,
                  "failed Fn down is surfaced without a stuck key")
        }

        do {
            let harness = VoiceFnHoldHarness()
            harness.controller.setEnabled(true)
            _ = harness.controller.startVoice()
            harness.controller.shutdown()
            check(harness.events == [true, false] && harness.controller.phase == .idle,
                  "shutdown balances an in-flight held Fn immediately")
        }
    }

    private static func testSessionLifecycle(
        check: (_ condition: @autoclosure () -> Bool, _ label: String) -> Void
    ) {
        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(false)
            check(!harness.controller.startVoice(), "Typeless path defaults disabled")
            check(!harness.controller.receive([1, 2, 3]), "disabled path rejects audio")
            check(!harness.controller.stopVoice(), "disabled path has no session to stop")
            check(harness.functionKeyEvents.isEmpty && harness.enqueuedAudio.isEmpty,
                  "disabled path preserves the existing voice route")
        }

        do {
            let harness = VoiceFnHarness(functionKeyResults: [false])
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "enabled path accepts start")
            harness.scheduler.advance(by: 0.15)
            check(harness.failures == [.startTapFailed], "opening Fn failure is surfaced")
            check(harness.functionKeyEvents == [true], "opening failure attempted only key down")
            check(!harness.controller.stopVoice(), "failed opening leaves no active session")
            harness.scheduler.runAll()
            check(harness.functionKeyEvents == [true],
                  "failed opening never emits a closing Fn tap")
        }

        do {
            let harness = VoiceFnHarness(functionKeyResults: [true, false, true, true, true])
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "opening release-failure fixture starts")
            harness.scheduler.advance(by: 0.15)
            harness.scheduler.advance(by: 0.12)
            check(harness.failures == [.startTapFailed],
                  "failed scheduled opening release is still surfaced")
            check(harness.functionKeyEvents == [true, false, false, true, false],
                  "successful cleanup release is paired with a closing Fn tap")
            check(harness.controller.phase == .idle,
                  "opening release failure converges without leaving Typeless active")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "opening session starts before disable")
            harness.scheduler.advance(by: 0.15)
            check(harness.functionKeyEvents == [true], "opening tap is in flight")
            var disabled = false
            harness.controller.setEnabled(false) { disabled = true }
            check(harness.functionKeyEvents == [true, false, true, false],
                  "disable completes in-flight opening and immediately closes the pair")
            check(!disabled, "disable waits for the physical release edge")
            check(!harness.controller.stopVoice() && disabled,
                  "physical release completes opening-disable cleanup")
            harness.scheduler.runAll()
            check(harness.functionKeyEvents == [true, false, true, false],
                  "cancelled opening task cannot post a stale tap")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "normal session starts")
            check(harness.controller.receive([1, 2, 3]), "pre-roll is accepted")
            check(harness.enqueuedAudio.isEmpty, "pre-roll waits for opening Fn tap")
            harness.scheduler.advance(by: 0.15)
            check(harness.functionKeyEvents == [true], "opening Fn goes down after delay")
            harness.scheduler.advance(by: 0.12)
            check(harness.functionKeyEvents == [true, false], "opening Fn tap is balanced")
            check(harness.enqueuedAudio == [[1, 2, 3]],
                  "pre-roll is delivered only after opening tap succeeds")
            check(harness.controller.receive([4, 5]), "active audio is accepted")
            check(harness.enqueuedAudio == [[1, 2, 3], [4, 5]],
                  "active audio is delivered directly")
            check(harness.controller.stopVoice(), "release begins drain")
            check(harness.drainCompletions.count == 1,
                  "release requests one audio drain")
            check(harness.functionKeyEvents == [true, false],
                  "closing Fn waits for audio drain")
            harness.completeNextDrain()
            check(harness.functionKeyEvents == [true, false, true],
                  "closing Fn starts only after drain completes")
            harness.scheduler.advance(by: 0.12)
            check(harness.functionKeyEvents == [true, false, true, false],
                  "closing Fn tap is balanced")
            check(harness.controller.phase == .idle, "normal session returns idle")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "short session starts before opening tap")
            check(harness.controller.receive([6, 5, 4]), "short session buffers pre-roll")
            check(harness.controller.stopVoice(), "short release is retained during opening")
            check(harness.enqueuedAudio.isEmpty && harness.drainCompletions.isEmpty,
                  "short release does not end the receipt before opening finishes")
            harness.scheduler.advance(by: 0.15)
            harness.scheduler.advance(by: 0.12)
            check(harness.enqueuedAudio == [[6, 5, 4]],
                  "short-session pre-roll is enqueued after the opening tap")
            check(harness.drainCompletions.count == 1,
                  "receipt/drain boundary runs only after short-session pre-roll flush")
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            check(harness.controller.phase == .idle,
                  "short session closes cleanly after its counted pre-roll")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            harness.startActiveSession()
            check(harness.controller.stopVoice(), "first rapid session begins drain")
            check(harness.controller.startVoice(), "second rapid session is queued")
            check(harness.controller.receive([9, 8, 7]), "second pre-roll is retained")
            check(harness.controller.stopVoice(), "queued second session can end early")
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            check(harness.controller.phase == .starting(2),
                  "second session receives a fresh generation")
            harness.scheduler.advance(by: 0.15)
            harness.scheduler.advance(by: 0.12)
            check(harness.enqueuedAudio.last == [9, 8, 7],
                  "second generation keeps its own pre-roll")
            check(harness.drainCompletions.count == 1,
                  "already-ended second generation drains after activation")
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            check(harness.controller.phase == .idle, "rapid sessions finish without overlap")
            check(harness.functionKeyEvents == [
                true, false, true, false,
                true, false, true, false,
            ], "rapid generations keep two complete independent tap pairs")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            harness.startActiveSession()
            var disabled = false
            harness.controller.setEnabled(false) { disabled = true }
            check(!disabled && harness.drainCompletions.count == 1,
                  "disable waits for active audio drain")
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            check(harness.controller.phase == .idle,
                  "disable closes the active target session")
            check(!harness.controller.stopVoice() && disabled,
                  "disable completion waits for the remote release edge")
            check(harness.functionKeyEvents == [true, false, true, false],
                  "disable produces exactly one matching close tap")
        }

        do {
            let harness = VoiceFnHarness(functionKeyResults: [true, true, false])
            harness.controller.setEnabled(true)
            harness.startActiveSession()
            harness.controller.shutdown()
            check(harness.failures == [.stopTapFailed],
                  "shutdown surfaces an immediate closing-tap down failure")
            check(harness.functionKeyEvents == [true, false, true],
                  "failed immediate tap-down never emits an unmatched Fn-up")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "deferred-disable fixture starts")
            var cleanupCompleted = false
            harness.controller.setEnabled(false) { cleanupCompleted = true }
            check(!cleanupCompleted,
                  "disable before physical release deliberately defers mapping cleanup")
            harness.controller.shutdown()
            check(cleanupCompleted && harness.controller.phase == .idle,
                  "disconnect/shutdown acts as the terminal edge and releases cleanup")
        }

        do {
            let harness = VoiceFnHarness()
            harness.controller.setEnabled(true)
            harness.startActiveSession()
            harness.controller.suspend()
            harness.completeNextDrain()
            harness.scheduler.advance(by: 0.12)
            check(harness.controller.phase == .idle && harness.controller.isSuspended,
                  "disconnect cleanup drains and reaches suspended idle")
            check(!harness.controller.startVoice(), "suspended controller rejects new starts")
            harness.controller.resume()
            check(harness.controller.startVoice(), "reconnect resumes sessions")
            harness.scheduler.advance(by: 0.27)
            check(harness.controller.phase == .active(2),
                  "reconnect starts a new generation")
            harness.controller.shutdown()
            check(harness.controller.phase == .idle,
                  "shutdown cleans an active generation immediately")
            check(Array(harness.functionKeyEvents.suffix(2)) == [true, false],
                  "shutdown emits the matching final close tap")
        }

        do {
            let harness = VoiceFnHarness()
            var readinessCompletion: ((VoiceFnTapDestinationWaitResult) -> Void)?
            harness.destinationReadiness = { completion in
                readinessCompletion = completion
                return .waiting(VoiceFnTapScheduledTask {})
            }
            harness.rebuildController()
            harness.controller.setEnabled(true)
            check(harness.controller.startVoice(), "destination-wait session starts")
            harness.controller.setEnabled(false)
            readinessCompletion?(.ready)
            harness.scheduler.runAll()
            check(harness.functionKeyEvents.isEmpty,
                  "stale destination completion cannot enter a cancelled generation")
            check(harness.controller.stopVoice() == false,
                  "cancelled generation consumes the final remote release without a tap")
        }
    }
}

private final class MappingServiceBox {
    let registryID: UInt64?
    let locationID: UInt32?
    var mappings: [HIDUsageMapping]
    var acceptsWrites: Bool
    var writeCount = 0

    init(
        registryID: UInt64?,
        locationID: UInt32? = nil,
        mappings: [HIDUsageMapping],
        acceptsWrites: Bool = true
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.mappings = mappings
        self.acceptsWrites = acceptsWrites
    }

    lazy var service = RemoteVoiceMappingService(
        registryID: registryID,
        locationID: locationID,
        readMappings: { [unowned self] in mappings },
        setMappings: { [unowned self] mappings in
            writeCount += 1
            guard acceptsWrites else { return false }
            self.mappings = mappings
            return true
        }
    )
}

private final class VoiceFnHarness {
    let scheduler = VoiceFnManualScheduler()
    var functionKeyEvents: [Bool] = []
    var functionKeyResults: [Bool]
    var enqueuedAudio: [[Int16]] = []
    var drainCompletions: [() -> Void] = []
    var failures: [VoiceFnTapFailure] = []
    var destinationReadiness: VoiceFnTapSessionController.DestinationReadiness = { _ in .immediate }
    private(set) var controller: VoiceFnTapSessionController!

    init(functionKeyResults: [Bool] = []) {
        self.functionKeyResults = functionKeyResults
        rebuildController()
    }

    func rebuildController() {
        controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: destinationReadiness,
            setFunctionKeyPressed: { [unowned self] pressed in
                functionKeyEvents.append(pressed)
                return functionKeyResults.isEmpty ? true : functionKeyResults.removeFirst()
            },
            enqueueAudio: { [unowned self] samples in
                enqueuedAudio.append(samples)
            },
            drainAudio: { [unowned self] completion in
                drainCompletions.append(completion)
            },
            onFailure: { [unowned self] failure in
                failures.append(failure)
            }
        )
    }

    func startActiveSession() {
        guard controller.startVoice() else { fatalError("session did not start") }
        scheduler.advance(by: 0.15)
        scheduler.advance(by: 0.12)
    }

    func completeNextDrain() {
        guard !drainCompletions.isEmpty else { fatalError("no pending drain") }
        drainCompletions.removeFirst()()
    }
}

private final class VoiceFnHoldHarness {
    var events: [Bool] = []
    var results: [Bool]
    var failures: [VoiceFnTapFailure] = []
    var drainCompletions: [() -> Void] = []
    private(set) var controller: VoiceFnHoldSessionController!

    init(results: [Bool] = []) {
        self.results = results
        controller = VoiceFnHoldSessionController(
            setFunctionKeyPressed: { [unowned self] pressed in
                events.append(pressed)
                return self.results.isEmpty ? true : self.results.removeFirst()
            },
            drainAudio: { [unowned self] completion in
                drainCompletions.append(completion)
            },
            onFailure: { [unowned self] failure in failures.append(failure) }
        )
    }

    func completeDrain() {
        guard !drainCompletions.isEmpty else { fatalError("no pending Fn-hold drain") }
        drainCompletions.removeFirst()()
    }
}

private final class VoiceFnManualScheduler {
    private struct Entry {
        let id: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var nextID = 0
    private var entries: [Entry] = []
    private var cancelledIDs = Set<Int>()

    lazy var schedule: VoiceFnTapSessionController.Scheduler = { [unowned self] delay, operation in
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, deadline: currentTime + delay, operation: operation))
        return VoiceFnTapScheduledTask { [weak self] in
            self?.cancelledIDs.insert(id)
        }
    }

    func advance(by interval: TimeInterval) {
        let target = currentTime + interval
        while let next = entries
            .filter({ !cancelledIDs.contains($0.id) && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline })
        {
            entries.removeAll { $0.id == next.id }
            currentTime = next.deadline
            next.operation()
        }
        currentTime = target
    }

    func runAll() {
        while let deadline = entries
            .filter({ !cancelledIDs.contains($0.id) })
            .map(\.deadline)
            .min()
        {
            advance(by: max(0, deadline - currentTime))
        }
    }
}
