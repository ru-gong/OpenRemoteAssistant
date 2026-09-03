import Foundation
import CoreGraphics

enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case power, microphone, up, left, ok, right, down, back, home, menu
    case volumeUp = "volume_up", volumeDown = "volume_down", tv
    var id: String { rawValue }
    var title: String {
        switch self {
        case .power: return "电源"
        case .microphone: return "语音"
        case .up: return "上"
        case .left: return "左"
        case .ok: return "确认"
        case .right: return "右"
        case .down: return "下"
        case .back: return "返回"
        case .home: return "主页"
        case .menu: return "菜单"
        case .volumeUp: return "音量＋"
        case .volumeDown: return "音量－"
        case .tv: return "TV"
        }
    }
    var symbol: String {
        switch self {
        case .power: return "power"
        case .microphone: return "mic.fill"
        case .up: return "chevron.up"
        case .left: return "chevron.left"
        case .ok: return "checkmark"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        case .back: return "arrow.uturn.backward"
        case .home: return "house.fill"
        case .menu: return "line.3.horizontal"
        case .volumeUp: return "plus"
        case .volumeDown: return "minus"
        case .tv: return "tv"
        }
    }
    /// RC003 reports ordinary buttons through HID report 1. The microphone key
    /// is deliberately excluded from the HID allowlist because the same press
    /// also drives the ATVV control channel; using only that GATT edge prevents
    /// a single physical press from firing a mapping twice.
    var isVerifiedHIDInput: Bool { self != .microphone }
    var canMap: Bool { true }
    var usage: UInt16 {
        switch self {
        case .power: return 0x66
        case .microphone: return 0x3E
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .home: return 0x4A
        case .menu: return 0x65
        case .volumeUp: return 0x80
        case .volumeDown: return 0x81
        case .tv: return 0x35
        }
    }
}

enum VoiceShortcutBehavior: String, Codable, Equatable {
    case off
    case holdFunction
    case toggleFunction
}

enum VoiceInputPreset: String, CaseIterable, Identifiable, Hashable {
    case off
    case typeless
    case doubao
    case weType
    case lightningDirect
    case lightningAssist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "不联动快捷键"
        case .typeless: return "Typeless · 点按 Fn"
        case .doubao: return "豆包输入法 · 按住 Fn"
        case .weType: return "微信输入法 · 按住 Fn"
        case .lightningDirect: return "闪电说“直接说” · 点按 Fn"
        case .lightningAssist: return "闪电说“帮我说” · 按住 Fn"
        }
    }

    var behavior: VoiceShortcutBehavior {
        switch self {
        case .off: return .off
        case .typeless, .lightningDirect: return .toggleFunction
        case .doubao, .weType, .lightningAssist: return .holdFunction
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "只传送遥控器声音，不向系统发送语音快捷键。"
        case .typeless:
            return "语音流开始前短点一次 Fn，松开并送完尾音后再点一次。"
        case .doubao:
            return "按住遥控器语音键时保持 Fn 按下，送完尾音后释放；豆包内请选择“按住说话”。"
        case .weType:
            return "按住遥控器语音键时保持 Fn 按下，送完尾音后释放；微信输入法内请选择长按模式。"
        case .lightningDirect:
            return "语音流开始前短点一次 Fn，松开并送完尾音后再点一次；闪电说内把“直接说”快捷键设为 Fn。"
        case .lightningAssist:
            return "按住遥控器语音键时保持 Fn 按下，送完尾音后释放；闪电说内把“帮我说”快捷键设为 Fn。"
        }
    }

    var readinessTitle: String {
        switch behavior {
        case .off: return "未启用"
        case .holdFunction: return "Fn 长按已就绪"
        case .toggleFunction: return "Fn 点按已就绪"
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var displayName: String
    static let allowedModifiers = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue
    var isValid: Bool {
        keyCode < 127 && ![54,55,56,57,58,59,60,61,62,63].contains(keyCode)
            && modifiers & ~Self.allowedModifiers == 0
            && !displayName.isEmpty && displayName.count <= 64
            && displayName.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum MappingAction: Codable, Equatable {
    case shortcut(KeyCombo)
    case modifier(flag: UInt64)
    case systemKey(UInt16)
    case disabled
    var display: String {
        switch self {
        case .shortcut(let combo):
            return combo.displayName + (usesSoftwareFn && !combo.displayName.contains("软件 Fn") ? " · 软件 Fn" : "")
        case .modifier(let flag):
            switch flag {
            case CGEventFlags.maskCommand.rawValue: return "⌘ Command（按住）"
            case CGEventFlags.maskControl.rawValue: return "⌃ Control（按住）"
            case CGEventFlags.maskAlternate.rawValue: return "⌥ Option（按住）"
            case CGEventFlags.maskShift.rawValue: return "⇧ Shift（按住）"
            case CGEventFlags.maskSecondaryFn.rawValue: return "Fn（软件按住）"
            default: return "不支持的修饰键"
            }
        case .systemKey(0): return "音量＋"
        case .systemKey(1): return "音量－"
        case .systemKey(7): return "静音"
        case .systemKey(16): return "播放 / 暂停"
        case .systemKey(let code): return "媒体键 \(code)"
        case .disabled: return "不执行动作"
        }
    }
    var isValid: Bool {
        switch self {
        case .shortcut(let combo): return combo.isValid
        case .modifier(let flag):
            return [CGEventFlags.maskCommand.rawValue, CGEventFlags.maskControl.rawValue,
                    CGEventFlags.maskAlternate.rawValue, CGEventFlags.maskShift.rawValue,
                    CGEventFlags.maskSecondaryFn.rawValue].contains(flag)
        case .systemKey(let code): return [0, 1, 7, 16].contains(code)
        case .disabled: return true
        }
    }
    var usesSoftwareFn: Bool {
        switch self {
        case .shortcut(let combo): return combo.modifiers & CGEventFlags.maskSecondaryFn.rawValue != 0
        case .modifier(let flag): return flag == CGEventFlags.maskSecondaryFn.rawValue
        case .systemKey, .disabled: return false
        }
    }
}

struct KeyPreset: Identifiable {
    let id: String
    let title: String
    let action: MappingAction
    static func key(_ id: String, _ label: String, _ code: UInt16, _ flags: CGEventFlags = []) -> KeyPreset {
        .init(id: id, title: label, action: .shortcut(.init(keyCode: code, modifiers: flags.rawValue, displayName: label)))
    }
    static let all: [KeyPreset] = [
        key("return", "Return ↩", 36), key("escape", "Esc ⎋", 53),
        key("space", "空格", 49), key("tab", "Tab ⇥", 48), key("delete", "Delete ⌫", 51),
        key("up", "↑", 126), key("down", "↓", 125), key("left", "←", 123), key("right", "→", 124),
        key("home", "Home ↖", 115), key("end", "End ↘", 119),
        key("page_up", "Page Up ⇞", 116), key("page_down", "Page Down ⇟", 121),
        key("copy", "⌘ C · 复制", 8, .maskCommand), key("paste", "⌘ V · 粘贴", 9, .maskCommand),
        key("cut", "⌘ X · 剪切", 7, .maskCommand), key("undo", "⌘ Z · 撤销", 6, .maskCommand),
        key("select_all", "⌘ A · 全选", 0, .maskCommand),
        key("app_switch", "⌘ Tab · 切换应用", 48, .maskCommand),
        key("spotlight", "⌘ 空格 · Spotlight", 49, .maskCommand),
        key("screenshot", "⇧ ⌘ 4 · 区域截图", 21, [.maskShift, .maskCommand]),
        key("browser_back", "⌘ [ · 后退", 33, .maskCommand),
        key("browser_forward", "⌘ ] · 前进", 30, .maskCommand),
        key("context_menu", "⇧ F10 · 菜单", 109, .maskShift),
        key("f5", "F5", 96), key("f13", "F13", 105), key("f14", "F14", 107),
        key("f15", "F15", 113), key("f16", "F16", 106),
        .init(id: "fn", title: "Fn（软件按住）", action: .modifier(flag: CGEventFlags.maskSecondaryFn.rawValue)),
        .init(id: "volume_up", title: "音量＋", action: .systemKey(0)),
        .init(id: "volume_down", title: "音量－", action: .systemKey(1)),
        .init(id: "mute", title: "静音", action: .systemKey(7)),
        .init(id: "play_pause", title: "播放 / 暂停", action: .systemKey(16)),
        .init(id: "disabled", title: "不执行动作", action: .disabled)
    ]
}

enum MappingDefaults {
    static let deviceVendor = 0x2717
    static let deviceProduct = 0x32B8
    static var bindings: [String: MappingAction] {
        var result: [String: MappingAction] = [:]
        let presets: [RemoteButton: String] = [.up:"up", .down:"down", .left:"left", .right:"right",
            .ok:"return", .back:"escape", .home:"home", .menu:"context_menu",
            .volumeUp:"volume_up", .volumeDown:"volume_down"]
        for button in RemoteButton.allCases {
            result[button.id] = presets[button].flatMap { id in KeyPreset.all.first { $0.id == id }?.action } ?? .disabled
        }
        return result
    }
}

struct EngineStatus {
    var isEnabled: Bool
    var message: String
    var deviceConnected: Bool
}
