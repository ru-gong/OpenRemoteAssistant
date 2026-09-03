import AppKit
import CoreGraphics

/// Real AppKit event objects, inspected locally only. The suite never posts an
/// event, installs an event monitor, requests access, or opens a HID device.
@main
enum RecorderTests {
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
            count += 1
        }
        func character(_ value: Int) -> String { String(UnicodeScalar(UInt32(value))!) }
        func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [],
                   characters: String, ignoringModifiers: String? = nil) -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                isARepeat: false, keyCode: code) else {
                fatalError("AppKit did not construct the test event")
            }
            return event
        }
        func recordedLabel(_ event: NSEvent, fnHeld: Bool = false) -> String {
            let flags = KeyNames.recordedModifiers(event, physicalFnHeld: fnHeld)
            let code = KeyNames.normalizedKeyCode(event)
            return KeyNames.modifierLabel(.init(rawValue: UInt(flags))) + KeyNames.label(for: code, event: event)
        }
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let command = CGEventFlags.maskCommand.rawValue
        let shift = CGEventFlags.maskShift.rawValue

        // Cocoa's function bit denotes special keys as well as the Fn modifier.
        let up = event(126, flags: [.function], characters: character(NSUpArrowFunctionKey))
        expect(up.type == .keyDown && up.modifierFlags.contains(.function), "construct real Cocoa arrow with function bit")
        expect(KeyNames.normalizedKeyCode(up) == 126, "ordinary Up keeps its arrow key code")
        expect(KeyNames.recordedModifiers(up, physicalFnHeld: false) == 0, "ordinary Up does not become Fn+Up")
        expect(recordedLabel(up) == "↑", "ordinary Up displays without Fn")

        let f5 = event(96, flags: [.function], characters: character(NSF5FunctionKey))
        expect(KeyNames.normalizedKeyCode(f5) == 96, "F5 keeps its key code")
        expect(KeyNames.recordedModifiers(f5, physicalFnHeld: false) == 0, "ordinary F5 does not become Fn+F5")
        expect(recordedLabel(f5) == "F5", "ordinary F5 displays without Fn")
        let shiftF5 = event(96, flags: [.shift, .function], characters: character(NSF5FunctionKey))
        expect(KeyNames.recordedModifiers(shiftF5, physicalFnHeld: false) == shift, "Shift F5 retains Shift without inventing Fn")
        expect(recordedLabel(shiftF5) == "⇧ F5", "Shift F5 label is readable")

        let fnLetter = event(8, flags: [.function], characters: "c")
        expect(KeyNames.normalizedKeyCode(fnLetter) == 8, "Fn letter remains a letter key")
        expect(KeyNames.recordedModifiers(fnLetter, physicalFnHeld: true) == fn, "observed Fn press is retained for a letter")
        expect(recordedLabel(fnLetter, fnHeld: true) == "Fn C", "Fn letter label includes Fn once")
        expect(KeyNames.recordedModifiers(fnLetter, physicalFnHeld: false) == 0, "function flag alone is insufficient proof of physical Fn")
        let commandFnLetter = event(8, flags: [.command, .function], characters: "c")
        expect(KeyNames.recordedModifiers(commandFnLetter, physicalFnHeld: true) == command | fn, "Command and observed Fn can combine")
        expect(recordedLabel(commandFnLetter, fnHeld: true) == "⌘ Fn C", "Command Fn letter label")

        // Test the translated Unicode navigation result explicitly. These are
        // constructed events, not claims about a specific physical Fn shortcut.
        let translatedHome = event(126, flags: [.function], characters: character(NSHomeFunctionKey))
        expect(KeyNames.normalizedKeyCode(translatedHome) == 115, "translated arrow uses Home output")
        expect(KeyNames.recordedModifiers(translatedHome, physicalFnHeld: true) == 0, "translated Home is not mapped again as Fn+Home")
        expect(recordedLabel(translatedHome, fnHeld: true) == "Home ↖", "translated Home has one clear target label")
        let shiftedHome = event(123, flags: [.shift, .function], characters: character(NSHomeFunctionKey))
        expect(KeyNames.normalizedKeyCode(shiftedHome) == 115, "translated Left uses Home output")
        expect(KeyNames.recordedModifiers(shiftedHome, physicalFnHeld: true) == shift, "translated Home preserves Shift but removes consumed Fn")
        expect(recordedLabel(shiftedHome, fnHeld: true) == "⇧ Home ↖", "Shift translated Home target")
        let pageUp = event(126, flags: [.function], characters: character(NSPageUpFunctionKey))
        expect(KeyNames.normalizedKeyCode(pageUp) == 116, "translated Up can preserve Page Up")
        expect(recordedLabel(pageUp, fnHeld: true) == "Page Up ⇞", "translated Page Up does not repeat Fn")
        let forwardDelete = event(51, flags: [.function], characters: character(NSDeleteFunctionKey))
        expect(KeyNames.normalizedKeyCode(forwardDelete) == 117, "translated Delete becomes forward delete")
        expect(recordedLabel(forwardDelete, fnHeld: true) == "向前删除 ⌦", "forward-delete label does not repeat Fn")

        let directHome = event(115, flags: [.function], characters: character(NSHomeFunctionKey))
        expect(KeyNames.recordedModifiers(directHome, physicalFnHeld: false) == 0, "ordinary Home function flag does not create Fn")
        expect(recordedLabel(directHome) == "Home ↖", "ordinary Home label")

        // The installed Mac layout maps virtual key 18 to base character 1.
        // AppKit recomputes the unshifted character; the label must not be ⇧ !.
        let shiftOne = event(18, flags: [.shift], characters: "!", ignoringModifiers: "!")
        expect(KeyNames.normalizedKeyCode(shiftOne) == 18, "Shift 1 keeps the physical main key")
        expect(KeyNames.recordedModifiers(shiftOne, physicalFnHeld: false) == shift, "Shift 1 retains Shift")
        expect(KeyNames.label(for: 18, event: shiftOne) == "1", "Shift 1 displays the base key rather than exclamation")
        expect(recordedLabel(shiftOne) == "⇧ 1", "Shift 1 complete target label")

        let commandC = event(8, flags: [.command], characters: "c")
        expect(KeyNames.recordedModifiers(commandC, physicalFnHeld: false) == command, "Command C modifier retained")
        expect(KeyNames.label(for: 8, event: commandC) == "C", "letter label is uppercase")
        expect(recordedLabel(commandC) == "⌘ C", "Command C complete target label")

        let noisyFlags = event(8, flags: [.command, .capsLock, .numericPad, .function], characters: "C")
        expect(KeyNames.recordedModifiers(noisyFlags, physicalFnHeld: false) == command, "Caps, keypad and unobserved function bits are not stored as modifiers")
        let allModifiers = event(8, flags: [.control, .option, .shift, .command, .function], characters: "C")
        let expected = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | shift | command | fn
        expect(KeyNames.recordedModifiers(allModifiers, physicalFnHeld: true) == expected, "all supported observed modifiers are preserved")
        expect(recordedLabel(allModifiers, fnHeld: true) == "⌃ ⌥ ⇧ ⌘ Fn C", "modifier labels retain stable display order")
        let combo = KeyCombo(keyCode: KeyNames.normalizedKeyCode(commandFnLetter),
            modifiers: KeyNames.recordedModifiers(commandFnLetter, physicalFnHeld: true),
            displayName: recordedLabel(commandFnLetter, fnHeld: true))
        expect(combo.isValid && MappingAction.shortcut(combo).usesSoftwareFn, "recorded Fn combination passes model validation and keeps software-Fn status")
        print("PASS \(count) AppKit recorder checks; events constructed locally only, none posted.")
    }
}
