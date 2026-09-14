// SPDX-License-Identifier: GPL-3.0-only
// Button model and mapping engine, ported from the macOS original's
// RemoteButton/MappingEngine semantics: 13 remote buttons → target key
// sequences (modifiers + main key), persisted as JSON.

using System.Text;
using System.Text.Json;

namespace OpenRemoteAssistant.Win;

public enum RemoteButton
{
    Power, Microphone, Up, Left, Ok, Right, Down, Back, Home, Menu, VolumeUp, VolumeDown, Tv,
}

public static class RemoteButtonExtensions
{
    public static string Id(this RemoteButton button) => button switch
    {
        RemoteButton.Power => "power",
        RemoteButton.Microphone => "microphone",
        RemoteButton.Up => "up",
        RemoteButton.Left => "left",
        RemoteButton.Ok => "ok",
        RemoteButton.Right => "right",
        RemoteButton.Down => "down",
        RemoteButton.Back => "back",
        RemoteButton.Home => "home",
        RemoteButton.Menu => "menu",
        RemoteButton.VolumeUp => "volume_up",
        RemoteButton.VolumeDown => "volume_down",
        RemoteButton.Tv => "tv",
        _ => button.ToString().ToLowerInvariant(),
    };

    public static string Title(this RemoteButton button) => button switch
    {
        RemoteButton.Power => "电源",
        RemoteButton.Microphone => "语音",
        RemoteButton.Up => "上",
        RemoteButton.Left => "左",
        RemoteButton.Ok => "确认",
        RemoteButton.Right => "右",
        RemoteButton.Down => "下",
        RemoteButton.Back => "返回",
        RemoteButton.Home => "主页",
        RemoteButton.Menu => "菜单",
        RemoteButton.VolumeUp => "音量＋",
        RemoteButton.VolumeDown => "音量－",
        RemoteButton.Tv => "TV",
        _ => button.ToString(),
    };

    public static readonly RemoteButton[] All =
    [
        RemoteButton.Power, RemoteButton.Microphone, RemoteButton.Up, RemoteButton.Left,
        RemoteButton.Ok, RemoteButton.Right, RemoteButton.Down, RemoteButton.Back,
        RemoteButton.Home, RemoteButton.Menu, RemoteButton.VolumeUp, RemoteButton.VolumeDown,
        RemoteButton.Tv,
    ];
}

/// <summary>One mapped target: modifier VKs followed by the main VK.</summary>
public sealed record KeyTarget(ushort[] VirtualKeys)
{
    public string Describe()
    {
        if (VirtualKeys.Length == 0) return "（未映射）";
        return string.Join("+", VirtualKeys.Select(VkNames.Name));
    }
}

/// <summary>Windows virtual-key names (subset covering common mappings).</summary>
public static class VkNames
{
    public static string Name(ushort vk) => vk switch
    {
        0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x13 => "Pause",
        0x1B => "Esc", 0x20 => "Space", 0x21 => "PageUp", 0x22 => "PageDown", 0x23 => "End", 0x24 => "Home",
        0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓", 0x2D => "Insert", 0x2E => "Delete",
        >= 0x30 and <= 0x39 => ((char)('0' + vk - 0x30)).ToString(),
        >= 0x41 and <= 0x5A => ((char)('A' + vk - 0x41)).ToString(),
        0x5B => "Win", 0x5C => "Win(右)", 0x5D => "菜单",
        >= 0x60 and <= 0x69 => $"小键盘{vk - 0x60}",
        0x6A => "小键盘*", 0x6B => "小键盘+", 0x6D => "小键盘-", 0x6E => "小键盘.", 0x6F => "小键盘/",
        >= 0x70 and <= 0x7B => $"F{vk - 0x6F}",
        0xA0 => "Shift(左)", 0xA1 => "Shift(右)", 0xA2 => "Ctrl(左)", 0xA3 => "Ctrl(右)",
        0xA4 => "Alt(左)", 0xA5 => "Alt(右)",
        _ => $"VK 0x{vk:X2}",
    };

    /// <summary>Common presets shown in the mapping UI (macOS parity plus Windows extras).</summary>
    public static readonly (string Label, ushort[] Vks)[] Presets =
    [
        ("方向键 ↑", [0x26]), ("方向键 ↓", [0x28]), ("方向键 ←", [0x25]), ("方向键 →", [0x27]),
        ("Enter 回车", [0x0D]), ("Esc 返回", [0x1B]), ("空格 播放/暂停", [0x20]),
        ("PageUp", [0x21]), ("PageDown", [0x22]),
        ("Ctrl+C 复制", [0xA2, 0x43]), ("Ctrl+V 粘贴", [0xA2, 0x56]), ("Ctrl+Z 撤销", [0xA2, 0x5A]),
        ("Ctrl+A 全选", [0xA2, 0x41]), ("Ctrl+S 保存", [0xA2, 0x53]), ("Ctrl+F 查找", [0xA2, 0x46]),
        ("Alt+Tab 切换", [0xA4, 0x09]), ("Win+D 桌面", [0x5B, 0x44]), ("Win+Tab 任务视图", [0x5B, 0x09]),
        ("F5 刷新", [0x74]), ("Ctrl+Shift+Tab", [0xA2, 0xA0, 0x09]), ("Ctrl+Tab", [0xA2, 0x09]),
        ("音量静音", [0xAD]), ("音量减", [0xAE]), ("音量加", [0xAF]),
        ("媒体播放/暂停", [0xB3]), ("媒体下一首", [0xB0]), ("媒体上一首", [0xB1]),
    ];

    /// <summary>Voice-shortcut target presets. Input methods often bind
    /// different actions to the LEFT and RIGHT modifiers (右Ctrl 说话 / 左Alt
    /// 切换…), so both sides are offered explicitly.</summary>
    public static readonly (string Label, ushort[] Vks)[] VoicePresets =
    [
        ("F2", [0x71]), ("F3", [0x72]), ("F4", [0x73]), ("F5", [0x74]),
        ("F6", [0x75]), ("F8", [0x77]), ("F9", [0x78]),
        ("Ctrl（左）", [0xA2]), ("Ctrl（右）", [0xA3]),
        ("Shift（左）", [0xA0]), ("Shift（右）", [0xA1]),
        ("Alt（左）", [0xA4]), ("Alt（右）", [0xA5]),
        ("空格", [0x20]), ("Enter", [0x0D]),
    ];
}

/// <summary>
/// RC003-MS consumer-control report decoder. The remote sends HID consumer
/// reports whose usages we map to the 13 logical buttons. Layout based on the
/// upstream DeviceProfile acceptance tuple and observed Xiaomi remotes.
/// </summary>
public sealed class Rc003ReportDecoder
{
    // VK-based recognition (LL hook provides vk). VK is what the OS layer
    // settled on for the key — more reliable than raw scancode across stacks.
    public static RemoteButton? FromVirtualKey(uint vk) => vk switch
    {
        0x26 => RemoteButton.Up,      // VK_UP
        0x28 => RemoteButton.Down,    // VK_DOWN
        0x25 => RemoteButton.Left,    // VK_LEFT
        0x27 => RemoteButton.Right,   // VK_RIGHT
        0x0D => RemoteButton.Ok,      // VK_RETURN
        0x08 => RemoteButton.Back,    // VK_BACK
        VoiceKeyVk => RemoteButton.Microphone,
        _ => null,
    };

    /// <summary>
    /// The voice key also arrives as an ordinary keyboard key: holding it makes
    /// the remote repeat VK_F5 at the auto-repeat rate (~32/s, measured on the
    /// user's RC003 on 2026-09-12 — scan=0x3F, vk=116). The voice audio channel
    /// is separate, so this key is swallowed and nothing is sent in its place
    /// (see the empty targets entry in RefreshSuppressibleKeys). Left alone it
    /// would refresh whatever window has focus, several times a second, for as
    /// long as the user is dictating.
    /// </summary>
    public const uint VoiceKeyVk = 0x74; // VK_F5

    // Generic desktop / keyboard scan codes the remote is known to emit
    // (direction pad arrives as arrow keys; consumer keys arrive as usages).
    public const int ScanUp = 0x48, ScanDown = 0x50, ScanLeft = 0x4B, ScanRight = 0x4D, ScanOk = 0x1C;
    // Live captures from the paired RC003 (2026-09-11 app.log): the D-pad DOES
    // send plain arrow scan codes — Up arrives as scan=0x48 with the E0 flag
    // and VK_UP (38), Down as scan=0x50 with E0 and VK_DOWN (40). An earlier
    // capture that showed Backspace for navigation was taken while the stack
    // was in a different state and no longer reproduces; the entry is kept so
    // a remote that really does send Backspace for Back is still recognised.
    public const int ScanBackBksp = 0x0E;
    // Live captures (2026-09-12 22:33 app.log): menu arrives as the keyboard
    // APPS key (scan 0x5D, VK_APPS 93), TV as backquote (scan 0x29,
    // VK_OEM_3 192). Both are ordinary keyboard events — mappable and
    // swallowable once listed in VksFor. Home was captured at 22:43:
    // scan 0x47 with E0 flag, VK_HOME (36).
    public const int ScanMenuApps = 0x5D;
    public const int ScanTvBackquote = 0x29;
    public const int ScanHome = 0x47;

    /// <summary>
    /// Virtual keys that identify each button on the wire. Used by the keyboard
    /// filter to know which keys a mapping is allowed to swallow.
    /// </summary>
    public static IEnumerable<uint> VksFor(RemoteButton button) => button switch
    {
        RemoteButton.Up => [0x26],
        RemoteButton.Down => [0x28],
        RemoteButton.Left => [0x25],
        RemoteButton.Right => [0x27],
        RemoteButton.Ok => [0x0D],
        RemoteButton.Back => [0x08],
        RemoteButton.Menu => [0x5D],      // VK_APPS — captured 2026-09-12
        RemoteButton.Tv => [0xC0],        // VK_OEM_3 backquote — captured 2026-09-12
        RemoteButton.Home => [0x24],      // VK_HOME — captured 2026-09-12
        _ => [],
    };

    public static RemoteButton? FromKeyboardScan(int scanCode, bool extended)
    {
        // NOTE: some BT HID stacks deliver arrow-key scan codes WITHOUT the E0
        // extended flag, so the flag is not required here. These are the
        // ordinary arrow keys, so a physical keyboard matches them too; this is
        // only a fallback for stacks that report no virtual key, and which
        // device actually sent the key is decided by RemoteKeyboardFilter.
        return scanCode switch
        {
            ScanUp => RemoteButton.Up,
            ScanDown => RemoteButton.Down,
            ScanLeft => RemoteButton.Left,
            ScanRight => RemoteButton.Right,
            ScanOk => RemoteButton.Ok,
            ScanBackBksp => RemoteButton.Back,
            ScanMenuApps => RemoteButton.Menu,
            ScanTvBackquote => RemoteButton.Tv,
            ScanHome => RemoteButton.Home,
            _ => null,
        };
    }

    /// <summary>Consumer-control HID reports (usage page 0x0C).</summary>
    public static RemoteButton? FromConsumerUsage(ushort usage) => usage switch
    {
        0x30 => RemoteButton.Power,
        0x45 => RemoteButton.Ok,
        0x22 => RemoteButton.Back,
        0x23 => RemoteButton.Home,
        0x40 => RemoteButton.Menu,
        0xE9 => RemoteButton.VolumeUp,
        0xEA => RemoteButton.VolumeDown,
        0x99 => RemoteButton.Tv,          // Channel Up repurposed on this remote
        _ => null,
    };

    /// <summary>Parses a raw HID consumer report: [reportId, lo, hi, …] usage pairs.</summary>
    public static List<RemoteButton> ParseConsumerReport(byte[] report)
    {
        var result = new List<RemoteButton>();
        for (int i = 1; i + 1 < report.Length; i += 2)
        {
            var usage = (ushort)(report[i] | report[i + 1] << 8);
            if (usage == 0) continue;
            if (FromConsumerUsage(usage) is { } button) result.Add(button);
        }
        return result;
    }
}

/// <summary>Voice-key shortcut behaviour, mirroring the macOS Fn presets.</summary>
public enum VoiceShortcutMode
{
    /// <summary>Voice key only opens the remote microphone (default).</summary>
    Off,
    /// <summary>Each press of the voice key taps the target once: press #1
    /// starts dictation, press #2 stops it (Typeless-style toggle).</summary>
    Toggle,
    /// <summary>The target key is HELD while the voice button is held
    /// (input-method style: the software listens while the key is down).</summary>
    Hold,
    /// <summary>Hold-to-talk for tap-toggle software: pressing the voice key
    /// TAPS the target (start), RELEASING it taps the target again (stop +
    /// transcribe). One hold gesture = two taps of the shortcut.</summary>
    HoldTap,
}

/// <summary>Persisted per-button mapping + enabled flag + voice shortcut config.</summary>
public sealed class MappingStore
{
    private readonly string _file;
    private Dictionary<string, ushort[]> _map = [];
    public bool Enabled { get; private set; }
    public VoiceShortcutMode VoiceMode { get; private set; } = VoiceShortcutMode.Off;
    public ushort[]? VoiceTarget { get; private set; }

    /// <summary>Raised after any persisted change so the engine can refresh
    /// the set of keys the keyboard filter is allowed to swallow.</summary>
    public event Action? Changed;

    public MappingStore(string file)
    {
        _file = file;
        Load();
    }

    public KeyTarget? Get(RemoteButton button) =>
        button == RemoteButton.Microphone
            ? null // voice key belongs to the voice shortcut, not button mapping
            : _map.TryGetValue(button.Id(), out var vks) && vks.Length > 0 ? new KeyTarget(vks) : null;

    public void Set(RemoteButton button, ushort[]? vks)
    {
        // The voice key is not a mappable button: its press/release drives the
        // voice shortcut below. Silently refuse here so a stale UI or a
        // hand-edited config cannot turn it into an ordinary key.
        if (button == RemoteButton.Microphone) return;
        if (vks is null || vks.Length == 0) _map.Remove(button.Id());
        else _map[button.Id()] = vks;
        Save();
    }

    public void SetEnabled(bool enabled)
    {
        Enabled = enabled;
        Save();
    }

    public void SetVoiceShortcut(VoiceShortcutMode mode, ushort[]? target)
    {
        VoiceMode = mode;
        VoiceTarget = mode == VoiceShortcutMode.Off ? null : target;
        Save();
    }

    /// <summary>
    /// One-click restore: drop every per-button mapping (all buttons back to
    /// "未映射") and reset the voice shortcut to its factory default
    /// (toggle mode on F2). The master enable switch is intentionally left
    /// as-is so the user's on/off choice is preserved.
    /// </summary>
    public void ResetToDefaults()
    {
        _map.Clear();
        VoiceMode = VoiceShortcutMode.Toggle;
        VoiceTarget = [0x71]; // F2
        Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_file)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(_file));
            var root = doc.RootElement;
            if (root.TryGetProperty("enabled", out var enabledEl)) Enabled = enabledEl.GetBoolean();
            if (root.TryGetProperty("voiceMode", out var modeEl)
                && Enum.TryParse<VoiceShortcutMode>(modeEl.GetString(), true, out var mode))
                VoiceMode = mode;
            // Legacy configs (or explicit "off") upgrade to the default toggle mode.
            if (VoiceMode == VoiceShortcutMode.Off) VoiceMode = VoiceShortcutMode.Toggle;
            if (VoiceTarget is null && VoiceMode != VoiceShortcutMode.Off)
                VoiceTarget = [0x71]; // default F2
            if (root.TryGetProperty("voiceTarget", out var targetEl) && targetEl.ValueKind == JsonValueKind.Array)
            {
                var vks = targetEl.EnumerateArray()
                    .Where(e => e.ValueKind == JsonValueKind.Number)
                    .Select(e => (ushort)e.GetUInt16()).ToArray();
                if (vks.Length > 0) VoiceTarget = vks;
            }
            if (root.TryGetProperty("buttons", out var buttonsEl) && buttonsEl.ValueKind == JsonValueKind.Object)
            {
                var migrate = false;
                foreach (var entry in buttonsEl.EnumerateObject())
                {
                    // "microphone" was once exposed as a mappable button; that
                    // was a dead entry then and is refused now. Drop it on load.
                    if (entry.Name == RemoteButton.Microphone.Id()) { migrate = true; continue; }
                    if (entry.Value.ValueKind != JsonValueKind.Array) continue;
                    var vks = entry.Value.EnumerateArray()
                        .Where(e => e.ValueKind == JsonValueKind.Number)
                        .Select(e => (ushort)e.GetUInt16()).ToArray();
                    if (vks.Length > 0) _map[entry.Name] = vks;
                }
                if (migrate) Save(); // rewrite the file without the dead entry
            }
        }
        catch { /* corrupt file: start fresh */ }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var json = new StringBuilder("{\n  \"enabled\": ").Append(Enabled ? "true" : "false").Append(',');
            json.Append("\n  \"voiceMode\": \"").Append(VoiceMode.ToString().ToLowerInvariant()).Append("\",");
            json.Append("\n  \"voiceTarget\": ").Append(VoiceTarget is { } t ? $"[{string.Join(", ", t)}]" : "null").Append(',');
            var known = RemoteButtonExtensions.All.Select(b => b.Id()).ToHashSet();
            known.Remove(RemoteButton.Microphone.Id()); // never persisted as a button mapping
            var keys = _map.Keys.Where(known.Contains).OrderBy(k => k).ToList();
            json.Append("\n  \"buttons\": ");
            if (keys.Count == 0)
            {
                json.Append("{}\n}\n");
            }
            else
            {
                json.Append("{\n");
                for (int i = 0; i < keys.Count; i++)
                {
                    var key = keys[i];
                    json.Append("    \"").Append(key).Append("\": [")
                        .Append(string.Join(", ", _map[key])).Append(']');
                    json.Append(i < keys.Count - 1 ? ",\n" : "\n");
                }
                json.Append("  }\n}\n");
            }
            File.WriteAllText(_file, json.ToString());
        }
        catch { /* best effort */ }
        Changed?.Invoke();
    }
}

/// <summary>
/// Wires raw events → button identity → suppression decision + mapped injection.
/// The voice button drives the voice-shortcut session (toggle/hold), never mapping.
/// </summary>
public sealed class MappingEngine : IDisposable
{
    private readonly MappingStore _store;
    private readonly RemoteKeyboardFilter _filter = new();
    private readonly object _lock = new();
    private bool _voiceHolding;             // hold-mode: target key currently down
    private long _lastVoiceTapAt;           // toggle-mode: dedup guard for pathological repeats
    public Action<RemoteButton, string>? OnMapped;       // button, description
    public Action<string>? OnLog;
    /// <summary>Notifies the UI that the active voice mode changed (quick switch).</summary>
    public Action<string>? OnVoiceModeChanged;

    public MappingEngine(MappingStore store)
    {
        _store = store;
        _store.Changed += RefreshSuppressibleKeys;
        // The keyboard filter swallows the remote's native press, which also
        // hides it from Raw Input. This callback is what puts the mapped
        // target in its place.
        RemoteKeyboardFilter.Swallowed = OnSwallowed;
        // The voice key is swallow-only (empty target); its press/release
        // transitions drive the voice-shortcut session.
        RemoteKeyboardFilter.VoiceKeyTransition = OnVoiceKeyTransition;
    }

    /// <summary>
    /// Replaces one remote press the keyboard filter swallowed. The filter only
    /// swallows while the remote owns the keys, and a swallowed press never
    /// reaches <see cref="HandleRawEvent"/>, so this is the one injection path
    /// for it — the two can never both fire for the same press.
    /// </summary>
    private void OnSwallowed(uint vk, ushort[] target)
    {
        var button = Rc003ReportDecoder.FromVirtualKey(vk);
        OnLog?.Invoke(button is { } b
            ? $"[映射] 拦截遥控器「{b.Title()}」原生 {VkNames.Name((ushort)vk)} → {DescribeVks(target)}"
            : $"[映射] 拦截遥控器原生 {VkNames.Name((ushort)vk)} → {DescribeVks(target)}");
        _ = Task.Run(() =>
        {
            KeyInjector.Tap(target);
            if (button is { } mapped) OnMapped?.Invoke(mapped, DescribeVks(target));
        });
    }

    /// <summary>Installs the keyboard filter (idempotent) and republishes the
    /// keys it is allowed to swallow.</summary>
    public void Start() => EnsureStarted();

    public void EnsureStarted()
    {
        try
        {
            _filter.Install();
            OnLog?.Invoke(RemoteKeyboardFilter.HookInstalledOk
                ? "[映射] 键盘钩子自检通过。"
                : "[映射] 键盘钩子自检未确认（可能为启动高峰期的误判），继续监视。");
        }
        catch (Exception ex) { OnLog?.Invoke($"[映射] 键盘过滤器启用失败：{ex.Message}"); }
        RefreshSuppressibleKeys();
    }

    /// <summary>
    /// Publishes the virtual keys the keyboard filter may swallow and what each
    /// one should be replaced with. Only remote buttons whose native key is
    /// known are listed: swallowing a key we cannot identify would suppress the
    /// press without putting anything in its place.
    ///
    /// The voice key is the exception — it is listed with an EMPTY target, which
    /// means "swallow, send nothing". Its native key (VK_F5) is a by-product of
    /// holding the voice key; the audio never travels through the keyboard, so
    /// there is nothing to put in its place.
    /// </summary>
    private void RefreshSuppressibleKeys()
    {
        var targets = new Dictionary<uint, ushort[]>();
        if (_store.Enabled)
        {
            foreach (var button in RemoteButtonExtensions.All)
            {
                if (button == RemoteButton.Microphone) continue;
                if (_store.Get(button) is not { } mapped) continue;
                var vks = Rc003ReportDecoder.VksFor(button).ToList();
                if (vks.Count == 0)
                {
                    // Mapped but its native key is unknown → the filter cannot
                    // swallow it and the mapping silently does nothing. Say so.
                    OnLog?.Invoke($"[映射] 按钮 {button.Id()} 已映射，但其原生键码未知（未被捕获过），无法拦截。");
                    continue;
                }
                foreach (var vk in vks) targets[vk] = mapped.VirtualKeys;
            }
            targets[Rc003ReportDecoder.VoiceKeyVk] = [];
        }
        RemoteKeyboardFilter.SetRemoteKeyTargets(targets);
        if (targets.Count == 0) RemoteKeyboardFilter.ClearOwnership();
        OnLog?.Invoke($"[映射] 可拦截按键 {targets.Count} 个（启用={_store.Enabled}）");
        if (_store.Enabled)
            OnLog?.Invoke($"[映射] 语音键原生 {VkNames.Name((ushort)Rc003ReportDecoder.VoiceKeyVk)} 只拦截、不注入");
    }

    /// <summary>Feed from Raw Input. Returns the button handled, if any.</summary>
    public RemoteButton? HandleRawEvent(RawKeyEvent evt)
    {
        if (evt.ScanCode == -2)
        {
            OnLog?.Invoke($"[原始] 未订阅的设备类型 dwType={evt.VirtualKey}");
            return null;
        }
        if (evt.ScanCode < 0 && evt.HidReport is { Length: > 0 })
        {
            if (!evt.FromRemote) return null;
            OnLog?.Invoke($"[原始] 遥控器 Consumer 报告：{Convert.ToHexString(evt.HidReport)}");
            if (_store.Enabled) HandleConsumerReport(evt.HidReport);
            return null;
        }
        if (evt.ScanCode <= 0) return null;

        // The only place that learns which interface a key came from. Releases
        // matter most here: the keyboard filter swallows presses but always
        // lets releases through, so a release is how a press that was swallowed
        // still gets attributed to its device.
        RemoteKeyboardFilter.NoteObserved(evt.FromRemote, evt.Up);

        // Anything that is not the remote is dropped right here: mapping never
        // reacts to the built-in keyboards. A press the keyboard filter
        // swallowed never reaches this method at all — see OnSwallowed.
        if (!evt.FromRemote)
        {
            if (!evt.Up && Rc003ReportDecoder.FromVirtualKey(evt.VirtualKey) is { } shadowed)
                OnLog?.Invoke($"[原始] 本地键盘 vk={evt.VirtualKey}（{VkNames.Name((ushort)evt.VirtualKey)}）"
                              + $"与遥控器「{shadowed.Title()}」同码，已放行 dev={RemoteHidDevices.Describe(evt.DevicePath)}");
            return null;
        }
        if (!_store.Enabled) return null;

        if (!evt.Up)
            OnLog?.Invoke($"[原始] 遥控器 scan={evt.ScanCode} ext={evt.Extended} vk={evt.VirtualKey} "
                          + $"dev={RemoteHidDevices.Describe(evt.DevicePath)}");

        // VK-based recognition first: settled virtual keys are consistent across
        // Bluetooth stacks, unlike raw scancodes.
        var identified = evt.VirtualKey != 0
            ? Rc003ReportDecoder.FromVirtualKey(evt.VirtualKey)
              ?? Rc003ReportDecoder.FromKeyboardScan(evt.ScanCode, evt.Extended)
            : Rc003ReportDecoder.FromKeyboardScan(evt.ScanCode, evt.Extended);
        if (identified is null) return null;
        if (identified == RemoteButton.Microphone) return null;
        if (evt.Up) return null;
        OnLog?.Invoke($"[映射] 识别到按键：{identified.Value.Title()}");
        if (_store.Get(identified.Value) is { } mapped)
        {
            // Inject off the message pump: SendInput + the UI notification must
            // not stall the window while a key is being handled.
            _ = Task.Run(() =>
            {
                KeyInjector.Tap(mapped.VirtualKeys);
                OnMapped?.Invoke(identified.Value, mapped.Describe());
            });
        }
        return identified;
    }

    private void HandleConsumerReport(byte[] report)
    {
        var buttons = Rc003ReportDecoder.ParseConsumerReport(report);
        if (buttons.Count == 0)
        {
            // An all-zero consumer report closes any previously held usages.
            CompleteHoldButtons();
            return;
        }
        foreach (var button in buttons)
        {
            if (button == RemoteButton.Microphone) continue;
            if (_store.Get(button) is { } target)
            {
                KeyInjector.Tap(target.VirtualKeys);
                OnMapped?.Invoke(button, target.Describe());
            }
        }
        _lastConsumerButtons = buttons;
    }

    private List<RemoteButton> _lastConsumerButtons = [];

    private void CompleteHoldButtons() => _lastConsumerButtons.Clear();

    // ---------------- Voice-key shortcut session ----------------

    /// <summary>
    /// GATT voice service is streaming button events. While it is connected the
    /// keyboard-hook path must stand down, or every physical press fires
    /// HandleVoiceButton twice (hook + GATT) — in toggle mode that means
    /// "start" and "stop" land back to back and dictation never opens.
    /// </summary>
    public void SetGattVoiceActive(bool active)
    {
        _gattVoiceActive = active;
        OnLog?.Invoke(active
            ? "[语音快捷键] GATT 语音服务在线，语音键事件由其上报（键盘路径待命）"
            : "[语音快捷键] GATT 语音服务已断开，语音键事件由键盘路径接管");
    }
    private volatile bool _gattVoiceActive;

    /// <summary>
    /// Keyboard-hook feed: one event per physical press/release of the voice
    /// key (auto-repeat collapsed). Drives the configured shortcut mode.
    /// Called on the hook thread — anything slow is dispatched to a worker.
    /// </summary>
    private void OnVoiceKeyTransition(uint vk, bool down)
    {
        // GATT is reporting the button itself; do not double-fire.
        if (_gattVoiceActive) return;
        // Cheap guard first: no shortcut configured → nothing to do. Do the
        // real work on a worker thread; the hook thread must return promptly.
        if (!_store.Enabled || _store.VoiceMode == VoiceShortcutMode.Off || _store.VoiceTarget is null)
        {
            if (down) OnLog?.Invoke("[语音快捷键] 未启用（快捷键或模式未配置），语音键仅拦截不触发");
            return;
        }
        _ = Task.Run(() => { try { HandleVoiceButton(down); } catch (Exception ex) { OnLog?.Invoke($"[语音快捷键] 处理失败：{ex.Message}"); } });
    }

    /// <summary>
    /// Voice-key session.
    /// <see cref="VoiceShortcutMode.Toggle"/>: each press TAPS the target once
    /// — press #1 starts dictation, press #2 stops it (Typeless-style).
    /// <see cref="VoiceShortcutMode.Hold"/>: the target is held down while the
    /// button is held, released ~0.4 s after let-go (Doubao/WeChat IME style).
    /// <see cref="VoiceShortcutMode.HoldTap"/>: hold-to-talk for TAP-toggle
    /// software — press taps the target (start), release taps it again
    /// (stop + transcribe). One hold gesture = two taps.
    /// </summary>
    public void HandleVoiceButton(bool down)
    {
        if (!_store.Enabled || _store.VoiceMode == VoiceShortcutMode.Off || _store.VoiceTarget is not { } target)
            return;
        if (down)
        {
            switch (_store.VoiceMode)
            {
                case VoiceShortcutMode.Toggle:
                    // The hook collapses auto-repeat, but a flapping switch or a
                    // second press racing the previous tap still needs a floor.
                    long now = Environment.TickCount64;
                    if (now - _lastVoiceTapAt < 150) return;
                    _lastVoiceTapAt = now;
                    KeyInjector.Tap(target);
                    OnLog?.Invoke("[语音快捷键] 点按切换 → 已按一下 " + DescribeVks(target)
                                  + "（再按一下语音键结束）");
                    break;
                case VoiceShortcutMode.Hold:
                    lock (_lock)
                    {
                        if (_voiceHolding) return;
                        _voiceHolding = true;
                    }
                    KeyInjector.Press(target);
                    OnLog?.Invoke("[语音快捷键] 按住 → " + DescribeVks(target) + " 已按下（说话中）");
                    break;
                case VoiceShortcutMode.HoldTap:
                    lock (_lock)
                    {
                        if (_voiceHolding) return;
                        _voiceHolding = true;
                    }
                    long tapAt = Environment.TickCount64;
                    if (tapAt - _lastVoiceTapAt < 150) return;
                    _lastVoiceTapAt = tapAt;
                    KeyInjector.Tap(target);
                    OnLog?.Invoke("[语音快捷键] 按住说话 → 已按一下 " + DescribeVks(target)
                                  + "（松开语音键自动再按一下结束）");
                    break;
            }
        }
        else
        {
            switch (_store.VoiceMode)
            {
                case VoiceShortcutMode.Hold:
                    bool wasHolding;
                    lock (_lock) { wasHolding = _voiceHolding; _voiceHolding = false; }
                    if (!wasHolding) return;
                    // Release after a short drain so trailing audio still lands.
                    Task.Delay(400).ContinueWith(_ =>
                    {
                        KeyInjector.Release(target);
                        OnLog?.Invoke("[语音快捷键] 松开 → " + DescribeVks(target) + " 已释放");
                    });
                    break;
                case VoiceShortcutMode.HoldTap:
                    bool wasHoldTap;
                    lock (_lock) { wasHoldTap = _voiceHolding; _voiceHolding = false; }
                    if (!wasHoldTap) return;
                    // Second tap shortly after release (small drain so the
                    // software sees two distinct presses and trailing audio
                    // is inside the session).
                    Task.Delay(350).ContinueWith(_ =>
                    {
                        KeyInjector.Tap(target);
                        OnLog?.Invoke("[语音快捷键] 松开 → 自动再按一下 " + DescribeVks(target)
                                      + "（停止转写）");
                    });
                    break;
            }
        }
    }

    /// <summary>
    /// Quick mode switch without touching the shortcut key. Used by the UI
    /// button and (optionally) a global hotkey. Persists immediately.
    /// </summary>
    public void CycleVoiceMode()
    {
        var next = _store.VoiceMode switch
        {
            VoiceShortcutMode.Toggle => VoiceShortcutMode.HoldTap,
            VoiceShortcutMode.HoldTap => VoiceShortcutMode.Hold,
            _ => VoiceShortcutMode.Toggle,
        };
        // Cancel any in-flight hold so switching modes mid-sentence cannot
        // leave the target key stuck down.
        if (_store.VoiceMode == VoiceShortcutMode.Hold && _store.VoiceTarget is { } held)
        {
            bool wasHolding;
            lock (_lock) { wasHolding = _voiceHolding; _voiceHolding = false; }
            if (wasHolding) KeyInjector.Release(held);
        }
        _store.SetVoiceShortcut(next, _store.VoiceTarget);
        OnLog?.Invoke($"[语音快捷键] 模式切换 → {DescribeVoiceMode(next)}");
        OnVoiceModeChanged?.Invoke(next.ToString().ToLowerInvariant());
    }

    public static string DescribeVoiceMode(VoiceShortcutMode mode) => mode switch
    {
        VoiceShortcutMode.Toggle => "点按两下（按一下开始，再按一下结束）",
        VoiceShortcutMode.HoldTap => "按住说话·自动结束（按住=说话，松开自动停止+转写）",
        VoiceShortcutMode.Hold => "按住说话·按键式（按住=快捷键按着，松开=松开）",
        _ => "未启用",
    };

    private static string DescribeVks(ushort[] vks) => string.Join("+", vks.Select(VkNames.Name));

    public void Dispose()
    {
        // Fail safe: never leave a held shortcut key stuck down.
        if (_voiceHolding && _store.VoiceTarget is { } stuck) KeyInjector.Release(stuck);
        _voiceHolding = false;
        _store.Changed -= RefreshSuppressibleKeys;
        RemoteKeyboardFilter.Swallowed = null;
        RemoteKeyboardFilter.VoiceKeyTransition = null;
        RemoteKeyboardFilter.SetRemoteKeyTargets([]);
        RemoteKeyboardFilter.ClearOwnership();
        _filter.Dispose();
    }
}
