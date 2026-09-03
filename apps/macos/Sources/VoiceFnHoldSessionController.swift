// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 OpenRemoteAssistant contributors
// Added 2026-09-03.

import Foundation

/// Balanced software-Fn hold for push-to-talk applications. Fn is pressed
/// before the remote opens its microphone and released only after queued tail
/// audio drains. No PCM is retained here.
final class VoiceFnHoldSessionController {
    enum Phase: Equatable { case idle, held(UInt64), draining(UInt64) }

    typealias FunctionKeySetter = (Bool) -> Bool
    typealias AudioDrainer = (@escaping () -> Void) -> Void

    private let setFunctionKeyPressed: FunctionKeySetter
    private let drainAudio: AudioDrainer
    private let onFailure: (VoiceFnTapFailure) -> Void
    private var generation: UInt64 = 0
    private var functionKeyIsPressed = false
    private var idleCompletions: [() -> Void] = []
    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isSuspended = false

    init(
        setFunctionKeyPressed: @escaping FunctionKeySetter,
        drainAudio: @escaping AudioDrainer,
        onFailure: @escaping (VoiceFnTapFailure) -> Void
    ) {
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.drainAudio = drainAudio
        self.onFailure = onFailure
    }

    func setEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        isEnabled = enabled
        if enabled {
            completion?()
            return
        }
        if let completion { idleCompletions.append(completion) }
        terminate(drain: true, reportFailure: true)
    }

    func resume() { isSuspended = false }

    @discardableResult
    func startVoice() -> Bool {
        guard isEnabled, !isSuspended else { return false }
        switch phase {
        case .idle:
            generation &+= 1
            guard setFunctionKeyPressed(true) else {
                isEnabled = false
                onFailure(.holdPressFailed)
                return false
            }
            functionKeyIsPressed = true
            phase = .held(generation)
            return true
        case .held:
            return true
        case .draining:
            return false
        }
    }

    @discardableResult
    func stopVoice() -> Bool {
        guard case let .held(currentGeneration) = phase else {
            if phase == .idle { runIdleCompletions() }
            return phase != .idle
        }
        phase = .draining(currentGeneration)
        drainAudio { [weak self] in
            guard let self, self.generation == currentGeneration,
                  self.phase == .draining(currentGeneration) else { return }
            self.finishRelease(reportFailure: true)
        }
        return true
    }

    func suspend(completion: (() -> Void)? = nil) {
        isSuspended = true
        if let completion { idleCompletions.append(completion) }
        terminate(drain: true, reportFailure: true)
    }

    func shutdown() {
        isEnabled = false
        isSuspended = true
        generation &+= 1
        _ = releaseFunctionKey(reportFailure: false)
        phase = .idle
        runIdleCompletions()
    }

    private func terminate(drain: Bool, reportFailure: Bool) {
        switch phase {
        case .idle:
            _ = releaseFunctionKey(reportFailure: reportFailure)
            runIdleCompletions()
        case .held where drain:
            _ = stopVoice()
        case .held, .draining:
            generation &+= 1
            _ = releaseFunctionKey(reportFailure: reportFailure)
            phase = .idle
            runIdleCompletions()
        }
    }

    private func finishRelease(reportFailure: Bool) {
        _ = releaseFunctionKey(reportFailure: reportFailure)
        phase = .idle
        runIdleCompletions()
    }

    @discardableResult
    private func releaseFunctionKey(reportFailure: Bool) -> Bool {
        guard functionKeyIsPressed else { return true }
        let released = setFunctionKeyPressed(false)
        if released { functionKeyIsPressed = false }
        else if reportFailure {
            isEnabled = false
            onFailure(.holdReleaseFailed)
        }
        return released
    }

    private func runIdleCompletions() {
        guard phase == .idle else { return }
        let completions = idleCompletions
        idleCompletions.removeAll()
        completions.forEach { $0() }
    }
}
