import AppKit
import CoreGraphics

enum KeyNames {
    static func recordedModifiers(_ event: NSEvent, physicalFnHeld: Bool) -> UInt64 {
        var flags = UInt64(event.modifierFlags.rawValue) & KeyCombo.allowedModifiers & ~CGEventFlags.maskSecondaryFn.rawValue
        // Cocoa sets .function on arrows/F-keys even without physical Fn. Only
        // an observed Fn flagsChanged event qualifies; translated Fn+arrows
        // become their Home/Page key directly instead of a second Fn chord.
        if physicalFnHeld && normalizedKeyCode(event) == event.keyCode {
            flags |= CGEventFlags.maskSecondaryFn.rawValue
        }
        return flags
    }
    static func normalizedKeyCode(_ event: NSEvent) -> UInt16 {
        // Preserve Cocoa's translated Home/Page keys (e.g. Fn+arrow) without
        // synthesizing a global Fn modifier. Plain arrows retain arrow codes.
        let navigation: [UInt32: UInt16] = [UInt32(NSUpArrowFunctionKey):126, UInt32(NSDownArrowFunctionKey):125,
            UInt32(NSLeftArrowFunctionKey):123, UInt32(NSRightArrowFunctionKey):124,
            UInt32(NSHomeFunctionKey):115, UInt32(NSEndFunctionKey):119,
            UInt32(NSPageUpFunctionKey):116, UInt32(NSPageDownFunctionKey):121, UInt32(NSDeleteFunctionKey):117]
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first, let code = navigation[scalar.value] {
            return code
        }
        return event.keyCode
    }
    static func modifierLabel(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃ " : "") + (flags.contains(.option) ? "⌥ " : "")
        + (flags.contains(.shift) ? "⇧ " : "") + (flags.contains(.command) ? "⌘ " : "")
        + (flags.contains(.function) ? "Fn " : "")
    }
    static func label(for code: UInt16, event: NSEvent) -> String {
        let known: [UInt16: String] = [36:"Return ↩",48:"Tab ⇥",49:"空格",51:"Delete ⌫",53:"Esc ⎋",
            76:"Enter ⌤",115:"Home ↖",116:"Page Up ⇞",117:"向前删除 ⌦",119:"End ↘",121:"Page Down ⇟",
            123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",
            97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",
            113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        if let value = known[code] { return value }
        if let text = event.characters(byApplyingModifiers: [])?.uppercased(), !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), text.count <= 8 {
            return text
        }
        return "Key \(code)"
    }
}
