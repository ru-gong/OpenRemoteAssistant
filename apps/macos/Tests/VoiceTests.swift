// SPDX-License-Identifier: GPL-3.0-only
// Pure tests only. This executable never constructs RemoteVoiceService or an
// audio output, enumerates hardware, connects Bluetooth, or writes a recording.
import Foundation
import CoreAudio

@main
enum VoiceTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError(label) }
            checks += 1
        }
        let fallbackLayout = Data([0x0B, 1, 0, 0, 3, 0, 120, 0, 0])
        let standardLayout = Data([0x0B, 1, 0, 2, 3, 0, 120, 0, 0])
        check(VoiceDecodedFrameRoute.decide(typelessEnabled: false, controllerAccepted: false) == .direct,
              "ordinary microphone mode routes decoded audio directly")
        check(VoiceDecodedFrameRoute.decide(typelessEnabled: true, controllerAccepted: true) == .typeless,
              "Typeless mode routes only controller-accepted audio")
        check(VoiceDecodedFrameRoute.decide(typelessEnabled: true, controllerAccepted: false) == .stop,
              "Typeless controller failure stops instead of falling back to plain audio")
        check(RC003VoiceProtocol.getCapabilities == Data([0x0A,1,0,0,3,3]), "captured RC003-MS capability request")
        check(RC003VoiceProtocol.supportedCapabilities == Set([fallbackLayout, standardLayout]), "only the two observed nine-byte RC003-MS layouts are whitelisted")
        check(RC003VoiceProtocol.validCapabilities(fallbackLayout), "observed RC003-MS codec-bitmap fallback layout")
        check(RC003VoiceProtocol.validCapabilities(standardLayout), "observed RC003-MS standard v1 layout")
        for supported in [fallbackLayout, standardLayout] {
            for index in supported.indices {
                var mutated = supported
                mutated[index] ^= 0x01
                check(!RC003VoiceProtocol.validCapabilities(mutated), "one-byte capability mutation rejected at index \(index)")
            }
        }
        check(!RC003VoiceProtocol.validCapabilities(Data([0x0B,1,0,2,3,0,120])), "seven-byte standard layout rejected")
        check(!RC003VoiceProtocol.validCapabilities(Data([0x0B,1,0,0,3,0,120])), "truncated response rejected")
        check(!RC003VoiceProtocol.validCapabilities(Data([0x0B,1,0,1,3,0,120,0,0])), "8 kHz layout rejected")
        check(!RC003VoiceProtocol.validCapabilities(Data([0x0B,1,0,2,3,0,0,0,0])), "zero frame length rejected")
        check(!RC003VoiceProtocol.validCapabilities(Data([0x0B,2,0,2,3,0,120,0,0])), "unknown version rejected")
        check(!RC003VoiceProtocol.validCapabilities(Data()), "empty capabilities rejected")
        check(!RC003VoiceProtocol.validCapabilities(standardLayout + Data([0])), "extended capabilities rejected")
        check(!RC003VoiceProtocol.validCapabilities(fallbackLayout + Data(repeating: 0, count: 100)), "oversized capabilities rejected")
        check(RC003VoiceProtocol.microphoneClose(42) == Data([13,42]), "session-specific close")

        var audioHandshake = RC003VoiceHandshake(audioEnabled: true)
        check(!audioHandshake.notificationsReady && !audioHandshake.capabilitiesRequested, "new audio handshake does not send commands")
        check(!audioHandshake.confirm(.control), "audio handshake waits after only control subscription")
        check(!audioHandshake.confirm(.control), "duplicate control confirmation cannot request capabilities early")
        check(!audioHandshake.capabilitiesRequested, "GET_CAPS is deferred until both notifications match proven capture order")
        check(audioHandshake.confirm(.audio), "second required notification permits GET_CAPS")
        check(audioHandshake.notificationsReady && audioHandshake.capabilitiesRequested, "both audio channels are ready")
        check(!audioHandshake.confirm(.audio) && !audioHandshake.confirm(.control), "notification duplicates never request capabilities twice")
        var reverseHandshake = RC003VoiceHandshake(audioEnabled: true)
        check(!reverseHandshake.confirm(.audio) && reverseHandshake.confirm(.control), "notification callback ordering is independent")
        var controlHandshake = RC003VoiceHandshake(audioEnabled: false)
        check(!controlHandshake.confirm(.audio) && !controlHandshake.confirmed.contains(.audio), "button-only handshake never accepts an audio subscription")
        check(controlHandshake.confirm(.control), "button-only handshake needs only control notifications")
        check(controlHandshake.notificationsReady && !controlHandshake.confirm(.control), "button-only GET_CAPS also occurs once")

        var receipt = RC003AudioReceipt()
        check(receipt.deadlineToken == nil && receipt.frames == 0, "no audio receipt or deadline before an actual stream")
        check(!receipt.enqueued(sampleCount: 240) && receipt.samples == 0, "inactive receipt cannot claim audio")
        receipt.resetHold(); receipt.startStreaming()
        let firstDeadline = receipt.deadlineToken!
        check(receipt.frames == 0 && receipt.shouldTimeout(firstDeadline), "START only waits for audio and is subject to timeout")
        check(!receipt.enqueued(sampleCount: 0) && receipt.deadlineToken == firstDeadline, "empty/partial audio cannot refresh complete-frame deadline")
        check(receipt.enqueued(sampleCount: 240), "only first successfully enqueued frame requests publication")
        check(receipt.frames == 1 && receipt.samples == 240, "successful frame/sample receipt evidence")
        check(!receipt.shouldTimeout(firstDeadline), "received frame invalidates old no-audio timeout")
        let nextDeadline = receipt.deadlineToken!
        check(!receipt.enqueued(sampleCount: 240), "subsequent frames update counters without high-frequency status publication")
        check(receipt.frames == 2 && receipt.samples == 480 && !receipt.shouldTimeout(nextDeadline), "each complete frame renews inactivity deadline")
        let releasedDeadline = receipt.deadlineToken!
        receipt.end()
        check(!receipt.shouldTimeout(releasedDeadline) && receipt.deadlineToken == nil, "release disarms the no-audio deadline")
        check(receipt.frames == 2 && receipt.samples == 480, "hold-end publication can report final counters")
        receipt.resetHold(); receipt.startStreaming()
        check(receipt.frames == 0 && receipt.samples == 0, "next physical hold starts new receipt counters")
        check(!receipt.shouldTimeout(releasedDeadline), "old hold timeout cannot close a later hold")
        let silentFrame = VoiceIMAADPCMDecoder().decode(Data(repeating: 0, count: 120))
        check(silentFrame.allSatisfy { $0 == 0 } && receipt.enqueued(sampleCount: silentFrame.count), "valid zero PCM counts as received audio, not no data")
        var receiptStatus = RemoteVoiceStatus()
        receiptStatus.isReady = true; receiptStatus.isStreaming = true
        check(!receiptStatus.hasReceivedAudio, "connected/stream-started state alone is not received audio")
        receiptStatus.audioFrames = receipt.frames; receiptStatus.audioSamples = receipt.samples
        check(receiptStatus.hasReceivedAudio, "successful receipt supports audio-arrival UI")
        receiptStatus.isReady = false
        check(!receiptStatus.hasReceivedAudio, "stopped service does not present old counters as current received audio")

        var buttonsOnly = RC003VoiceHold(audioEnabled: false)
        check(buttonsOnly.control(Data([8])) == [.button(true), .beginHold], "control-only REQUEST does not open mic")
        let direct = Data([4,0,2,7])
        check(buttonsOnly.control(direct).isEmpty, "control-only START does not start an audio path")
        check(buttonsOnly.microphoneMayBeOpen, "self-started hardware mic tracked accurately")
        check(buttonsOnly.control(Data([0])) == [.button(false), .streamEnded, .closeMicrophone(7)], "release closes self-started mic")
        check(!buttonsOnly.held && !buttonsOnly.streaming, "control-only releases state")
        check(buttonsOnly.control(Data([0])).isEmpty, "duplicate release ignored")

        var repeated = RC003VoiceHold(audioEnabled: true)
        for i in 0..<1_024 {
            let sid = UInt8(i % 256)
            let begin = Data([4,0,2,sid])
            check(repeated.control(begin) == [.button(true), .beginHold, .streamStarted], "new direct physical hold \(i)")
            check(repeated.control(begin).isEmpty, "duplicate START preserves decoder \(i)")
            check(repeated.control(Data([8])).isEmpty, "duplicate REQUEST never opens twice \(i)")
            check(repeated.control(Data([0])) == [.button(false), .streamEnded, .closeMicrophone(sid)], "hold release \(i)")
        }
        check(!repeated.held && !repeated.microphoneMayBeOpen, "unlimited holds leave idle state")
        check(repeated.control(Data([8])) == [.button(true), .beginHold, .openMicrophone], "audio REQUEST explicit open")
        _ = repeated.control(direct)
        check(repeated.control(Data([4,0,2,8])) == [.failure("语音会话在按住期间改变。")], "session change fails")
        var invalid = RC003VoiceHold(audioEnabled: true)
        check(invalid.control(Data([4,0,1,9])) == [.failure("遥控器语音编码或会话标识异常。")], "invalid stream rejected")
        check(invalid.microphoneMayBeOpen && invalid.sessionID == 9, "invalid stream retains close ID")
        check(invalid.control(Data()) == [.failure("语音控制报告异常。")], "empty control rejected")

        check(VoiceIMAADPCMDecoder().decode(Data([0x7F])) == [11,-19], "high nibble first known vector")
        let stream = RC003VoicePCM()
        let partial = try stream.decode(Data(repeating: 0x11, count: 60))
        check(partial.isEmpty, "partial audio not decoded")
        let complete = try stream.decode(Data(repeating: 0x11, count: 60))
        check(complete.first?.count == 240, "complete 120 byte frame")
        try stream.synchronize(Data([10,0,0,0,3,232,0]))
        let synced = try stream.decode(Data(repeating: 0, count: 120))
        check(synced.first?.first == 1_000, "sync predictor applied")
        do { try stream.synchronize(Data([10,0,0,0,0,0,89])); fatalError("invalid sync accepted") }
        catch { checks += 1 }
        do { _ = try stream.decode(Data(repeating: 0, count: 4_097)); fatalError("oversized audio accepted") }
        catch { checks += 1 }
        let continuous = RC003VoicePCM()
        for _ in 0..<2_001 { _ = try continuous.decode(Data(repeating: 0, count: 120)) }
        check(continuous.sampleCount == 480_240,
              "decoder continues beyond the former thirty-second sample limit")
        let fresh = RC003VoicePCM()
        let freshDecoded = try fresh.decode(Data(repeating: 0, count: 120))
        check(freshDecoded.first?.first == 0, "new hold fresh decoder")

        func endpoint(input: Bool, uid: String? = nil, owner: String = VoiceAudioCatalog.pluginBundleID,
                      manufacturer: String = VoiceAudioCatalog.manufacturer,
                      transport: UInt32? = nil,
                      alive: Bool = true, inputChannels: Int? = nil, outputChannels: Int? = nil) -> VoiceEndpointIdentity {
            VoiceEndpointIdentity(uid: uid ?? (input ? VoiceAudioCatalog.inputUID : VoiceAudioCatalog.outputUID),
                name: input ? VoiceAudioCatalog.inputName : VoiceAudioCatalog.outputName,
                manufacturer: manufacturer, pluginBundleID: owner,
                transport: transport ?? (input ? VoiceAudioCatalog.inputTransport : VoiceAudioCatalog.outputTransport),
                inputChannels: inputChannels ?? (input ? 2 : 0),
                outputChannels: outputChannels ?? (input ? 0 : 2), isAlive: alive)
        }
        let input = endpoint(input: true), output = endpoint(input: false)
        check(VoiceAudioCatalog.compatibility(input: input, output: output) == .current,
              "current split transport pair is recognized")
        check(VoiceAudioCatalog.compatibility(
            input: endpoint(input: true, transport: kAudioDeviceTransportTypeVirtual), output: output) == .previousVirtualInput,
              "otherwise-identical pre-0.2.5 all-Virtual pair is recognized only as stale")
        check(VoiceAudioCatalog.compatibility(
            input: endpoint(input: true, transport: kAudioDeviceTransportTypeBuiltIn), output: output) == .invalid,
              "unrecognized public input transport is not stale-upgrade evidence")
        func provider(id: AudioObjectID = 10, classID: AudioClassID = kAudioPlugInClassID,
                      bundle: String = VoiceAudioCatalog.pluginBundleID, input: AudioDeviceID = 20,
                      output: AudioDeviceID = 30) -> VoiceAudioProvider {
            VoiceAudioProvider(pluginID: id, classID: classID, bundleID: bundle, inputDeviceID: input, outputDeviceID: output)
        }
        check(provider().matches(input: 20, output: 30), "system bundle lookup plus plug-in UID mappings associate both endpoints")
        check(!provider(id: kAudioObjectUnknown).matches(input: 20, output: 30), "unknown plug-in cannot associate a route")
        check(!provider(id: AudioObjectID(kAudioObjectSystemObject)).matches(input: 20, output: 30), "AudioSystem owner is not accepted as plug-in")
        check(!provider(classID: kAudioSystemObjectClassID).matches(input: 20, output: 30), "wrong plug-in class rejected")
        check(!provider(bundle: "other.plugin").matches(input: 20, output: 30), "foreign provider bundle rejected")
        check(!provider(input: 21).matches(input: 20, output: 30), "provider input translation must equal system input")
        check(!provider(output: 31).matches(input: 20, output: 30), "hidden provider output translation must equal system output")
        check(!provider(input: 30, output: 20).matches(input: 20, output: 30), "swapped provider UID translations rejected")
        check(!provider(input: 0).matches(input: 0, output: 30), "unknown system input rejected")
        check(!provider(output: 0).matches(input: 20, output: 0), "unknown system output rejected")
        check(!provider(input: 20, output: 20).matches(input: 20, output: 20), "same object cannot be both split endpoints")
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        let oneBuffer = header + MemoryLayout<AudioBuffer>.stride
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: header, capacity: header, announced: 0) == 0,
              "successful empty opposite-scope AudioBufferList is zero channels")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: kAudioHardwareUnknownPropertyError, byteCount: header, capacity: header, announced: 0) == nil,
              "failed channel query is not a successful zero-channel scope")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: oneBuffer, capacity: oneBuffer, announced: 1) == 1,
              "complete one-buffer layout accepted")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: oneBuffer, capacity: oneBuffer, announced: 2) == nil,
              "announced buffer count cannot exceed returned allocation")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: oneBuffer, capacity: header, announced: 1) == nil,
              "returned length cannot exceed allocation")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: header - 1, capacity: header, announced: 0) == nil,
              "partial AudioBufferList header rejected")
        check(VoiceAudioBufferLayout.validatedBufferCount(status: noErr, byteCount: oneBuffer, capacity: oneBuffer, announced: UInt32.max) == nil,
              "oversized count cannot overflow or walk beyond buffer")
        let deviceBytes = MemoryLayout<AudioDeviceID>.stride
        check(VoiceAudioBufferLayout.validatedDeviceCount(status: noErr, byteCount: 2 * deviceBytes, capacity: 3 * deviceBytes) == 2,
              "device enumeration shrinks to actual returned complete IDs")
        check(VoiceAudioBufferLayout.validatedDeviceCount(status: noErr, byteCount: deviceBytes + 1, capacity: 2 * deviceBytes) == nil,
              "partial device ID is rejected rather than floor-allocated")
        check(VoiceAudioBufferLayout.validatedDeviceCount(status: noErr, byteCount: 2 * deviceBytes, capacity: deviceBytes) == nil,
              "device enumeration return size cannot exceed capacity")
        check(VoiceAudioBufferLayout.validatedDeviceCount(status: kAudioHardwareBadObjectError, byteCount: 0, capacity: deviceBytes) == nil,
              "failed device list query is not valid empty response")
        var queueBudget = VoiceAudioQueueBudget(limit: 2)
        check(queueBudget.canCreate && queueBudget.didCreate() && queueBudget.count == 1,
              "first active AudioQueue reserves one bounded resource slot")
        check(queueBudget.canCreate && queueBudget.didCreate() && queueBudget.count == 2,
              "one replacement may overlap one asynchronously retiring queue")
        check(!queueBudget.canCreate && !queueBudget.didCreate() && queueBudget.count == 2,
              "stalled teardown cannot create an unbounded third AudioQueue")
        queueBudget.didDispose()
        check(queueBudget.canCreate && queueBudget.count == 1,
              "completed asynchronous disposal reopens exactly one slot")
        queueBudget.didDispose(); queueBudget.didDispose()
        check(queueBudget.count == 0, "duplicate retirement completion cannot underflow the queue budget")
        var disabledBudget = VoiceAudioQueueBudget(limit: 0)
        check(!disabledBudget.canCreate && !disabledBudget.didCreate(), "invalid zero budget fails closed")
        check(VoiceAudioChunkPlan.ranges(sampleCount: 0, samplesPerBuffer: 1_024,
                  availableBuffers: 0) == [], "empty audio needs no queue buffers")
        let preRollRanges = VoiceAudioChunkPlan.ranges(sampleCount: 4_320,
            samplesPerBuffer: 1_024, availableBuffers: 96)
        check(preRollRanges?.map(\.count) == [1_024, 1_024, 1_024, 1_024, 224],
              "Typeless pre-roll is split across fixed AudioQueue buffers")
        check(VoiceAudioChunkPlan.requiredBufferCount(sampleCount: 80_000,
                  samplesPerBuffer: 1_024) == 79,
              "maximum bounded Typeless pre-roll fits the allocated pool")
        check(VoiceAudioChunkPlan.ranges(sampleCount: 80_000, samplesPerBuffer: 1_024,
                  availableBuffers: 78) == nil,
              "an incomplete pre-roll reservation fails before partial enqueue")
        let drainNow: UInt64 = 1_000
        let drainDeadline = VoiceAudioDrainPolicy.deadline(after: drainNow)
        check(drainDeadline == drainNow + VoiceAudioDrainPolicy.timeoutNanoseconds,
              "normal voice release receives a bounded 750 ms drain deadline")
        check(VoiceAudioDrainPolicy.deadline(after: UInt64.max - 1) == UInt64.max,
              "drain deadline addition saturates instead of wrapping")
        check(VoiceAudioDrainPolicy.decision(isRunning: 1, now: drainNow, deadline: drainDeadline) == .wait,
              "running queue waits before its bounded deadline")
        check(VoiceAudioDrainPolicy.decision(isRunning: 0, now: drainNow, deadline: drainDeadline) == .drained,
              "stopped queue proves queued audio processing completed")
        check(VoiceAudioDrainPolicy.decision(isRunning: 1, now: drainDeadline, deadline: drainDeadline) == .forceRetire,
              "running queue is force-retired at the hard deadline")
        check(VoiceAudioDrainPolicy.decision(isRunning: nil, now: drainNow, deadline: drainDeadline) == .forceRetire,
              "unreadable queue state fails closed instead of waiting indefinitely")
        var levelGate = VoiceLevelPublicationGate()
        check(levelGate.shouldPublish(now: 100), "first audio frame publishes its level immediately")
        check(!levelGate.shouldPublish(now: 100 + VoiceLevelPublicationGate.minimumIntervalNanoseconds - 1),
              "per-frame level updates are throttled below 20 Hz")
        check(levelGate.shouldPublish(now: 100 + VoiceLevelPublicationGate.minimumIntervalNanoseconds),
              "level publishes again at the 20 Hz boundary")
        levelGate.reset()
        check(levelGate.shouldPublish(now: 1), "a new physical hold publishes its first level independently")
        check(levelGate.shouldPublish(now: 0), "monotonic clock rollback fails open without unsigned underflow")
        check(VoiceAudioCatalog.accepts(input: input, output: output), "dedicated split endpoints accepted")
        for uid in ["BlackHole2ch_UID", "BlackHole16ch_UID", "OrayVirtualAudioDevice", "BuiltInSpeakerDevice", "OpenRemoteAudio_2_UID "] {
            check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, uid: uid)), "foreign or near-match output rejected")
        }
        check(!VoiceAudioCatalog.accepts(input: endpoint(input: true, owner: "audio.existential.BlackHole"), output: output), "input plugin owner mismatch rejected")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, owner: "other.plugin")), "output plugin owner mismatch rejected")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, manufacturer: "Apple Inc.")), "manufacturer mismatch rejected")
        check(!VoiceAudioCatalog.accepts(input: endpoint(input: true, transport: kAudioDeviceTransportTypeVirtual), output: output), "public input must expose USB-compatible transport")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, transport: kAudioDeviceTransportTypeUSB)), "hidden writer must remain virtual")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, transport: kAudioDeviceTransportTypeBuiltIn)), "built-in transport rejected")
        check(!VoiceAudioCatalog.accepts(input: endpoint(input: true, alive: false), output: output), "dead input rejected")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, alive: false)), "dead output rejected")
        check(!VoiceAudioCatalog.accepts(input: endpoint(input: true, inputChannels: 0), output: output), "missing input rejected")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, outputChannels: 0)), "missing output rejected")
        check(!VoiceAudioCatalog.accepts(input: endpoint(input: true, outputChannels: 2), output: output), "unexpected public output rejected")
        check(!VoiceAudioCatalog.accepts(input: input, output: endpoint(input: false, inputChannels: 2)), "unexpected mirror input rejected")
        check(!VoiceAudioCatalog.accepts(input: output, output: input), "swapped endpoints rejected")
        print("PASS \(checks) voice protocol/decoder/route-policy checks; no hardware, recording or output created")
    }
}
