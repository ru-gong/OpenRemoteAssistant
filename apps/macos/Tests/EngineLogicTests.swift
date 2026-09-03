import Foundation
import CoreGraphics

/// Hardware-free checks. No permission prompt, HID open, or CGEvent.post occurs.
@main
struct EngineLogicTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "FAILED: \(name)")
            checks += 1
        }
        func parsed(_ bytes: [UInt8], id: UInt32 = 1) -> Set<UInt16>? {
            if case .keys(let values) = RC003HIDReport.parse(id: id, bytes: bytes) { return values }
            return nil
        }
        func isMalformed(_ bytes: [UInt8]) -> Bool {
            if case .malformed = RC003HIDReport.parse(id: 1, bytes: bytes) { return true }
            return false
        }
        func shortcut(_ code: UInt16, _ flags: CGEventFlags = []) -> MappingAction {
            .shortcut(.init(keyCode: code, modifiers: flags.rawValue, displayName: "test"))
        }
        check(VoiceInputPreset.typeless.behavior == .toggleFunction &&
              VoiceInputPreset.lightningDirect.behavior == .toggleFunction,
              "tap-to-toggle applications share the paired Fn behavior")
        check(VoiceInputPreset.doubao.behavior == .holdFunction &&
              VoiceInputPreset.weType.behavior == .holdFunction &&
              VoiceInputPreset.lightningAssist.behavior == .holdFunction,
              "push-to-talk applications share the held Fn behavior")
        check(VoiceInputPreset.off.behavior == .off &&
              VoiceInputPreset.allCases.count == 6,
              "voice application preset catalog is explicit and complete")
        let realSequence: [UInt16] = [0x35, 0x52, 0x51, 0x50, 0x4F, 0x28, 0xF1, 0x4A, 0x65, 0x66, 0x80, 0x81]
        for usage in realSequence {
            check(parsed([1, 0, 0, UInt8(usage), 0, 0, 0]) == [usage], "captured usage \(usage)")
        }
        check(parsed([1, 0, 0, 0, 0, 0, 0]) == [], "all-released report")
        check(parsed([0x35, 0, 0x66, 0, 0, 0]) == [0x35, 0x66], "six-byte payload without report ID")
        check(parsed([1, 0x52, 0, 0x52, 0, 0x51, 0]) == [0x52, 0x51], "duplicate slots deduplicated")
        check(isMalformed([1, 0, 0]), "short keyboard report rejected")
        check(isMalformed([0, 0, 0, 0, 0, 0, 0]), "incorrect embedded report ID rejected")
        check(isMalformed([1, 1, 0, 0, 0, 0, 0]), "rollover report rejected")
        check(isMalformed([1, 0, 0, 0, 0, 0, 0, 0]), "oversized keyboard report rejected")
        if case .ignored = RC003HIDReport.parse(id: 5, bytes: [0xAA]) { checks += 1 }
        else { fatalError("vendor report must not be interpreted") }

        let up: UInt16 = 0x52, down: UInt16 = 0x51
        let command = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        var input = MappingInputState()
        let plain: [UInt16: MappingAction] = [up: shortcut(126)]
        check(input.consume([up], mappings: plain) == [.keyboard(code: 126, down: true, flags: 0, modifier: false)], "normal down")
        check(input.consume([up], mappings: plain).isEmpty, "duplicate held reports do not repeat")
        check(input.consume([], mappings: plain) == [.keyboard(code: 126, down: false, flags: 0, modifier: false)], "normal release")
        check(input.consume([], mappings: plain).isEmpty, "duplicate release is inert")

        let copy: [UInt16: MappingAction] = [up: shortcut(8, .maskCommand)]
        check(input.consume([up], mappings: copy) == [
            .keyboard(code: 55, down: true, flags: command, modifier: true),
            .keyboard(code: 8, down: true, flags: command, modifier: false)
        ], "modifier precedes main key")
        check(input.releaseOutputs(keepPhysicalUsages: false) == [
            .keyboard(code: 8, down: false, flags: command, modifier: false),
            .keyboard(code: 55, down: false, flags: 0, modifier: true)
        ], "disable releases main key then modifier")
        check(input.heldActions.isEmpty && input.physicalUsages.isEmpty, "disable clears state")

        let shared: [UInt16: MappingAction] = [up: shortcut(8, .maskCommand), down: shortcut(9, .maskCommand)]
        _ = input.consume([up, down], mappings: shared)
        check(input.consume([down], mappings: shared) == [.keyboard(code: 8, down: false, flags: command, modifier: false)], "shared modifier remains held")
        check(input.consume([], mappings: shared) == [
            .keyboard(code: 9, down: false, flags: command, modifier: false),
            .keyboard(code: 55, down: false, flags: 0, modifier: true)
        ], "last owner releases shared modifier")

        let duplicateTarget: [UInt16: MappingAction] = [up: shortcut(8, .maskCommand), down: shortcut(8, .maskCommand)]
        _ = input.consume([up], mappings: duplicateTarget)
        check(input.consume([up, down], mappings: duplicateTarget).isEmpty, "same output has one down")
        check(input.consume([down], mappings: duplicateTarget).isEmpty, "same output not released by first owner")
        check(input.consume([], mappings: duplicateTarget).count == 2, "same output released once by final owner")

        _ = input.consume([up], mappings: copy)
        check(input.consume([up], mappings: [up: shortcut(9)]).isEmpty, "in-flight press retains old binding")
        check(input.releaseOutputs(keepPhysicalUsages: true).count == 2, "configuration change balances old binding")
        check(input.consume([up], mappings: [up: shortcut(9)]).isEmpty, "configuration change waits for next press")
        _ = input.consume([], mappings: plain)
        check(input.consume([up], mappings: [up: shortcut(9)]) == [.keyboard(code: 9, down: true, flags: 0, modifier: false)], "new binding fires after release and press")
        _ = input.releaseOutputs(keepPhysicalUsages: false)

        let powerAndTV: [UInt16: MappingAction] = [0x66: shortcut(0), 0x35: shortcut(1)]
        check(input.consume([0x66, 0x35], mappings: powerAndTV).count == 2, "RC003 power and TV usages can map")
        _ = input.releaseOutputs(keepPhysicalUsages: false)
        let unchecked: [UInt16: MappingAction] = [0x3E: shortcut(0), 0xFFFF: shortcut(0)]
        check(input.consume([0x3E, 0xFFFF], mappings: unchecked).isEmpty, "voice HID duplicate and unknown usages cannot map")
        check(input.heldActions.isEmpty, "suppressed or unknown keys never enter output state")
        _ = input.releaseOutputs(keepPhysicalUsages: false)
        check(input.consume([up], mappings: [up: .disabled]).isEmpty, "explicit disabled action is silent")
        _ = input.releaseOutputs(keepPhysicalUsages: false)
        let invalid = MappingAction.shortcut(.init(keyCode: 65535, modifiers: 0, displayName: "invalid"))
        check(input.consume([up], mappings: [up: invalid]).isEmpty, "invalid shortcut never injects")
        _ = input.releaseOutputs(keepPhysicalUsages: false)

        let media: [UInt16: MappingAction] = [up: .systemKey(0)]
        check(input.consume([up], mappings: media) == [.systemKey(code: 0, down: true)], "media down")
        check(input.releaseOutputs(keepPhysicalUsages: false) == [.systemKey(code: 0, down: false)], "media balanced on teardown")

        let twoModifiers: [UInt16: MappingAction] = [up: shortcut(8, [.maskControl, .maskCommand])]
        _ = input.consume([up], mappings: twoModifiers)
        check(input.releaseOutputs(keepPhysicalUsages: false) == [
            .keyboard(code: 8, down: false, flags: control | command, modifier: false),
            .keyboard(code: 55, down: false, flags: control, modifier: true),
            .keyboard(code: 59, down: false, flags: 0, modifier: true)
        ], "multi-modifier release flags clear progressively")
        check(MappingInputState.verifiedUsages == Set(realSequence), "allowlist exactly equals twelve supported RC003 HID usages")
        check(MappingInputState.verifiedUsages == HIDSessionRules.verifiedUsages, "privileged bridge allowlist matches the engine's verified physical keys")
        check(HIDSessionRules.vendorID == DeviceProfile.vendorID && HIDSessionRules.productID == DeviceProfile.productID,
              "privileged bridge and supported profile use the same fixed VID/PID")
        check(HIDSessionRules.openFailure(-536870207).code == "hid_privilege", "privilege refusal is not mislabeled device occupancy")
        check(RemoteButton.allCases.count == 13, "model includes all thirteen physical buttons")
        check(RemoteButton.tv.usage == 0x35 && RemoteButton.tv.isVerifiedHIDInput && RemoteButton.tv.canMap,
              "RC003 TV usage is supported and mappable")
        check(MappingInputState.verifiedUsages.contains(RemoteButton.tv.usage), "RC003 TV enters the HID allowlist")
        check(input.consume([RemoteButton.tv.usage], mappings: [RemoteButton.tv.usage: shortcut(106)]).count == 1,
              "TV can inject its configured F16")
        _ = input.releaseOutputs(keepPhysicalUsages: false)
        check(MappingDefaults.bindings[RemoteButton.tv.id] == .disabled, "TV default is explicitly inert")
        check(MappingDefaults.bindings[RemoteButton.menu.id] == KeyPreset.all.first { $0.id == "context_menu" }?.action, "menu default uses shared preset")
        check(MappingEngine.injectedEventMarker != 0, "events have a recorder exclusion marker")
        check(RemoteButton.ok.nativeEvents == [.keyboard(36)]
              && RemoteButton.tv.nativeEvents == [.keyboard(10), .keyboard(50)],
              "shared mode suppresses measured RC003 return and both observed TV key codes")
        check(RemoteButton.volumeUp.nativeEvents == [.systemKey(0)]
              && RemoteButton.volumeDown.nativeEvents == [.systemKey(1)],
              "shared mode recognizes the two native media events")
        check(RemoteButton.microphone.nativeEvents == [.keyboard(96)],
              "GATT voice edge can narrowly arm suppression for the physical F5 event")
        check(RemoteButton.back.nativeEvents.isEmpty,
              "a button without an observed macOS event does not suppress unrelated input")

        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let microphone = RemoteButton.microphone.usage
        let fnAction = MappingAction.modifier(flag: fn)
        check(fnAction.isValid && fnAction.usesSoftwareFn, "Fn standalone is explicitly identified as software Fn")
        check(fnAction.display.contains("软件按住"), "Fn display describes the hold behavior")
        check(!MappingAction.modifier(flag: 0).isValid, "empty modifier rejected")
        check(!MappingAction.modifier(flag: command | fn).isValid, "standalone modifier accepts exactly one flag")
        check(!MappingAction.modifier(flag: CGEventFlags.maskAlphaShift.rawValue).isValid, "Caps Lock toggle is not a hold modifier")
        check(shortcut(8, [.maskCommand, .maskSecondaryFn]).isValid, "Fn is accepted in key combinations")
        check(shortcut(8, .maskSecondaryFn).usesSoftwareFn, "Fn combination is marked as software Fn")
        check(!shortcut(63).isValid, "Fn cannot masquerade as an ordinary main key")
        check(RemoteButton.microphone.canMap && !RemoteButton.microphone.isVerifiedHIDInput,
              "GATT mapping deliberately suppresses the duplicate microphone HID usage")
        check(RemoteButton.power.canMap && RemoteButton.power.isVerifiedHIDInput, "RC003 power usage is mappable")
        check(MappingDefaults.bindings[RemoteButton.microphone.id] == .disabled, "microphone starts with no action")

        let fnMapping: [UInt16: MappingAction] = [up: fnAction]
        check(input.consume([up], mappings: fnMapping) == [
            .keyboard(code: 63, down: true, flags: fn, modifier: true)
        ], "Fn sends modifier-down without a main-key event")
        check(input.consume([up], mappings: fnMapping).isEmpty, "held Fn does not repeat")
        check(input.releaseOutputs(keepPhysicalUsages: false) == [
            .keyboard(code: 63, down: false, flags: 0, modifier: true)
        ], "Fn is balanced by modifier-up")

        let fnComboMapping: [UInt16: MappingAction] = [up: shortcut(8, [.maskCommand, .maskSecondaryFn])]
        check(input.consume([up], mappings: fnComboMapping) == [
            .keyboard(code: 55, down: true, flags: command, modifier: true),
            .keyboard(code: 63, down: true, flags: command | fn, modifier: true),
            .keyboard(code: 8, down: true, flags: command | fn, modifier: false)
        ], "Fn combination presses modifiers before its main key")
        check(input.releaseOutputs(keepPhysicalUsages: false) == [
            .keyboard(code: 8, down: false, flags: command | fn, modifier: false),
            .keyboard(code: 63, down: false, flags: command, modifier: true),
            .keyboard(code: 55, down: false, flags: 0, modifier: true)
        ], "Fn combination releases every modifier in reverse order")

        let voiceMapping: [UInt16: MappingAction] = [microphone: fnAction, up: shortcut(126)]
        check(input.consume([microphone], mappings: voiceMapping).isEmpty, "unverified HID microphone code cannot activate a configured GATT binding")
        check(input.physicalUsages.isEmpty, "HID microphone code is excluded from source union")
        check(input.consume([], mappings: voiceMapping, voiceButtonPressed: true) == [
            .keyboard(code: 63, down: true, flags: fn, modifier: true)
        ], "GATT down alone activates the microphone binding")
        check(input.consume([microphone], mappings: voiceMapping, voiceButtonPressed: true).isEmpty, "concurrent HID microphone candidate does not double-trigger GATT")
        check(input.consume([], mappings: voiceMapping, voiceButtonPressed: true).isEmpty, "HID all-released report cannot release GATT-held Fn")
        check(input.consume([up], mappings: voiceMapping, voiceButtonPressed: true) == [
            .keyboard(code: 126, down: true, flags: fn, modifier: false)
        ], "ordinary HID button joins a held GATT modifier")
        check(input.physicalUsages == [up, microphone], "source union includes both independently held buttons")
        check(input.consume([], mappings: voiceMapping, voiceButtonPressed: true) == [
            .keyboard(code: 126, down: false, flags: fn, modifier: false)
        ], "ordinary HID release preserves GATT modifier")
        check(input.consume([], mappings: voiceMapping, voiceButtonPressed: false) == [
            .keyboard(code: 63, down: false, flags: 0, modifier: true)
        ], "only GATT up releases its Fn binding")

        let sharedFn: [UInt16: MappingAction] = [microphone: fnAction, up: fnAction]
        _ = input.consume([up], mappings: sharedFn, voiceButtonPressed: true)
        check(input.consume([], mappings: sharedFn, voiceButtonPressed: true).isEmpty, "Fn remains held while either input source owns it")
        check(input.releaseOutputs(keepPhysicalUsages: false) == [
            .keyboard(code: 63, down: false, flags: 0, modifier: true)
        ], "teardown releases shared Fn once")
        check(input.physicalUsages.isEmpty && input.heldActions.isEmpty, "teardown clears GATT and HID logical state")
        _ = input.consume([], mappings: voiceMapping, voiceButtonPressed: true)
        _ = input.releaseOutputs(keepPhysicalUsages: true)
        check(input.consume([], mappings: [microphone: shortcut(49)], voiceButtonPressed: true).isEmpty, "GATT-held key does not retrigger after a configuration change")
        _ = input.consume([], mappings: voiceMapping, voiceButtonPressed: false)
        check(input.consume([], mappings: [microphone: shortcut(49)], voiceButtonPressed: true) == [
            .keyboard(code: 49, down: true, flags: 0, modifier: false)
        ], "new GATT binding applies after the next release and press")
        _ = input.releaseOutputs(keepPhysicalUsages: false)

        let engine = MappingEngine()
        check(!engine.status.isEnabled, "new engine does not activate hardware")
        var inactiveInputCallbacks = 0
        engine.onInput = { _ in inactiveInputCallbacks += 1 }
        engine.setVoiceButtonPressed(true)
        engine.setVoiceButtonPressed(false)
        check(!engine.status.isEnabled && inactiveInputCallbacks == 0, "GATT edges cannot activate an inactive engine")
        print("Engine logic: \(checks) checks passed; no hardware opened or events injected.")
    }
}
