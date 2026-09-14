// SPDX-License-Identifier: GPL-3.0-only
// Raw Input + low-level keyboard hook bridge.
//
// Raw Input is the authoritative source of button events: every WM_INPUT
// packet carries the HID device interface it came from, which is how the
// paired RC003-MS is told apart from the built-in keyboards.
//
// Suppressing the remote's *native* arrow/enter/back keys has one hard
// constraint, measured with a probe on this machine (tmp/probe_swallow.py):
// a key the low-level hook swallows DISAPPEARS FROM RAW INPUT. So Raw Input
// can never confirm a swallowed key, and "swallow, then ask Raw Input who it
// was, then re-inject if it was the keyboard" is impossible.
//
// The way out is to swallow only key-DOWNs and always pass key-UP through.
// A release can never make Windows act on its own (the key was never down),
// yet it still reaches Raw Input carrying the interface it came from. That
// gives the hook a live device signal for every press whose down it swallowed,
// and leads to the whole rule being one line:
//
//     whoever produced the most recent observed key owns the mapped keys.
//
//   * Remote pressed   -> its release is observed as remote, the remote keeps
//                         ownership, every further press is swallowed.
//   * Keyboard pressed -> its release is observed as the keyboard, ownership
//                         flips, and mapped keys go back to being passed
//                         through untouched.
//
// The worst case is a single wrong decision at each keyboard<->remote switch,
// which is the floor for this design: nothing inside a low-level hook carries
// device identity.

using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace OpenRemoteAssistant.Win;

public sealed record RawKeyEvent(int ScanCode, bool Extended, bool Up, uint VirtualKey, string DevicePath, bool FromRemote)
{
    public byte[]? HidReport { get; init; }
}

/// <summary>Identifies the remote's HID device interfaces among raw-input devices.</summary>
public static class RemoteHidDevices
{
    // RC003-MS Bluetooth HID interface: VID 0x2717 (Xiaomi) / PID 0x32B8.
    private const ushort RemoteVid = 0x2717;
    private const ushort RemotePid = 0x32B8;

    // Accepts both the plain USB form ("VID_2717&PID_32B8") and the Bluetooth
    // LE form Windows actually uses here ("DEV_VID&012717_PID&32B8"), where the
    // separators differ and the VID has a two-digit vendor-source prefix.
    // Match a complete VID/PID pair; never identify hardware by a fixed MAC.
    private static readonly Regex VidPidPattern = new(
        @"(?:^|[\\#&])(?:dev_)?vid[&_](?:0[12])?([0-9a-f]{4})[&_]+pid[&_]([0-9a-f]{4})(?=$|[\\#&_])",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static bool IsRemotePath(string? devicePath)
    {
        if (string.IsNullOrEmpty(devicePath)) return false;
        var match = VidPidPattern.Match(devicePath);
        return match.Success
               && ushort.TryParse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var vid)
               && ushort.TryParse(match.Groups[2].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var pid)
               && vid == RemoteVid
               && pid == RemotePid;
    }

    /// <summary>Short form for logs: drops the trailing interface GUID.</summary>
    public static string Describe(string devicePath)
    {
        if (string.IsNullOrEmpty(devicePath)) return "(未知)";
        var at = devicePath.LastIndexOf('{');
        return at > 2 ? devicePath[..(at - 1)] : devicePath;
    }
}

/// <summary>
/// Raw Input observer for keyboard-type input. RIDEV_INPUTSINK keeps events
/// flowing while unfocused; each event carries the source device interface so
/// remote input can be told apart from the real keyboards.
/// </summary>
public sealed class RawInputObserver : IDisposable
{
    public delegate void GetRawInputDataDelegate(RawKeyEvent evt);

    private const uint WM_INPUT = 0x00FF;
    private const uint RIDEV_REMOVE = 0x0000_0001;
    private const uint RIDEV_INPUTSINK = 0x0000_0100;
    private const uint RID_INPUT = 0x1000_0003;

    // RIDI_DEVICENAME. The previous value 0x2000000B is RIDI_DEVICEINFO: asking
    // for that returned a RID_DEVICE_INFO struct, so every device name decoded
    // to a lone control byte and no event could ever be attributed to the
    // remote. That single wrong constant is what made the remote look
    // "invisible to Raw Input".
    private const uint RIDI_DEVICENAME = 0x2000_0007;

    private const ushort RI_KEY_BREAK = 0x0001; // release
    private const ushort RI_KEY_E0 = 0x0002;    // E0-prefixed (arrows / nav cluster)
    private const ushort RI_KEY_E1 = 0x0004;    // E1-prefixed (Pause)

    private readonly IntPtr _window;
    private readonly List<RAWINPUTDEVICE> _registrations = [];

    public static event GetRawInputDataDelegate? StaticEvent;

    /// <summary>Reports internal failures instead of swallowing them silently.</summary>
    public static Action<string>? OnError;

    public RawInputObserver(IntPtr windowHandle)
    {
        _window = windowHandle;
        Register(0x01, 0x06); // Generic Desktop / Keyboard
        Register(0x0C, 0x01); // Consumer / Consumer Control
    }

    private void Register(ushort usagePage, ushort usage)
    {
        var device = new RAWINPUTDEVICE
        {
            usUsagePage = usagePage,
            usUsage = usage,
            dwFlags = RIDEV_INPUTSINK,
            hwndTarget = _window,
        };
        if (!RegisterRawInputDevices([device], 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>()))
            throw new InvalidOperationException($"RegisterRawInputDevices 失败: {usagePage}/{usage}");
        _registrations.Add(device);
    }

    /// <summary>Called from the window's WndProc for WM_INPUT.</summary>
    public static void ProcessWmInput(IntPtr lParam)
    {
        try
        {
            uint size = 0;
            GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf<RAWINPUTHEADER>());
            if (size == 0 || size > 4096) return;
            var buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                uint written = GetRawInputData(lParam, RID_INPUT, buffer, ref size, (uint)Marshal.SizeOf<RAWINPUTHEADER>());
                if (written == 0 || written == uint.MaxValue) return;
                var header = Marshal.PtrToStructure<RAWINPUTHEADER>(buffer);
                int headerSize = Marshal.SizeOf<RAWINPUTHEADER>();

                if (header.dwType == 1) // RIM_TYPEKEYBOARD
                {
                    var keyboard = Marshal.PtrToStructure<RAWKEYBOARD>(buffer + headerSize);
                    // Our own SendInput injections are stamped so they never get
                    // re-read as local activity.
                    if (keyboard.ExtraInformation == KeyInjector.Signature) return;
                    ushort flags = keyboard.Flags;
                    if ((flags & RI_KEY_E1) != 0) return; // Pause/Break prefix artifact

                    bool up = (flags & RI_KEY_BREAK) != 0 || keyboard.Message is 0x0101 or 0x0105;
                    bool extended = (flags & RI_KEY_E0) != 0;
                    int scan = keyboard.MakeCode;
                    if (scan == 0 && keyboard.VKey != 0) scan = ScanFromVirtualKey(keyboard.VKey);
                    if (scan == 0 && keyboard.VKey == 0) return;

                    var path = DevicePathFromHandle(header.hDevice);
                    StaticEvent?.Invoke(new RawKeyEvent(
                        scan, extended, up, keyboard.VKey, path, RemoteHidDevices.IsRemotePath(path)));
                }
                else if (header.dwType == 2) // RIM_TYPEHID (consumer-control reports)
                {
                    var hid = Marshal.PtrToStructure<RAWHID>(buffer + headerSize);
                    uint total = hid.dwSizeHid * hid.dwCount;
                    int dataOffset = headerSize + Marshal.SizeOf<RAWHID>();
                    if (total > 0 && total <= 512 && dataOffset + total <= header.dwSize)
                    {
                        var bytes = new byte[total];
                        Marshal.Copy(buffer + dataOffset, bytes, 0, bytes.Length);
                        var path = DevicePathFromHandle(header.hDevice);
                        StaticEvent?.Invoke(new RawKeyEvent(
                            -1, false, false, 0, path, RemoteHidDevices.IsRemotePath(path))
                        {
                            HidReport = bytes,
                            });
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        catch (Exception ex)
        {
            OnError?.Invoke($"Raw Input 处理异常：{ex.Message}");
        }
    }

    /// <summary>
    /// Some Bluetooth stacks hand us MakeCode=0 with only the virtual key set;
    /// recover the standard scan code so identity bookkeeping still works.
    /// </summary>
    private static int ScanFromVirtualKey(ushort vk) => vk switch
    {
        0x26 => 0x48, 0x28 => 0x50, 0x25 => 0x4B, 0x27 => 0x4D, // arrows
        0x0D => 0x1C,                                          // Enter / OK
        0x08 => 0x0E,                                          // Backspace / Back
        0x21 => 0x49, 0x22 => 0x51, 0x23 => 0x4F, 0x24 => 0x47, // PgUp PgDn End Home
        _ => 0,
    };

    /// <summary>Resolves the interface name of a device handle (RIDI_DEVICENAME).</summary>
    public static string DevicePathFromHandle(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return "";
        uint size = 0;
        GetRawInputDeviceInfo(handle, RIDI_DEVICENAME, IntPtr.Zero, ref size);
        if (size == 0 || size > 4096) return "";
        var buffer = Marshal.AllocHGlobal((int)size + 2);
        try
        {
            if (GetRawInputDeviceInfo(handle, RIDI_DEVICENAME, buffer, ref size) is 0 or uint.MaxValue) return "";
            return Marshal.PtrToStringAnsi(buffer) ?? "";
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>All raw-input devices, for the startup diagnostics log.</summary>
    public static List<(uint Type, string Path, bool Remote)> EnumerateDevices()
    {
        var result = new List<(uint, string, bool)>();
        uint count = 0;
        uint itemSize = (uint)Marshal.SizeOf<RAWINPUTDEVICELIST>();
        // NOTE: with a NULL list the API returns 0 even on success and reports
        // the device count through `count`, so only -1 means failure here.
        if (GetRawInputDeviceList(IntPtr.Zero, ref count, itemSize) == uint.MaxValue || count == 0)
            return result;
        var buffer = Marshal.AllocHGlobal((int)(itemSize * count));
        try
        {
            if (GetRawInputDeviceList(buffer, ref count, itemSize) == uint.MaxValue) return result;
            for (uint i = 0; i < count; i++)
            {
                var item = Marshal.PtrToStructure<RAWINPUTDEVICELIST>(buffer + (int)(i * itemSize));
                var path = DevicePathFromHandle(item.hDevice);
                result.Add((item.dwType, path, RemoteHidDevices.IsRemotePath(path)));
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return result;
    }

    public void Dispose()
    {
        foreach (var registration in _registrations)
        {
            var off = new RAWINPUTDEVICE
            {
                usUsagePage = registration.usUsagePage,
                usUsage = registration.usUsage,
                dwFlags = RIDEV_REMOVE,
                hwndTarget = IntPtr.Zero,
            };
            RegisterRawInputDevices([off], 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
        }
        _registrations.Clear();
    }

    // ---- P/Invoke ----
    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE
    {
        public ushort usUsagePage, usUsage;
        public uint dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICELIST
    {
        public IntPtr hDevice;
        public uint dwType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER
    {
        public uint dwType, dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWKEYBOARD
    {
        public ushort MakeCode, Flags, Reserved, VKey;
        public uint Message;
        public uint ExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWHID
    {
        public uint dwSizeHid, dwCount;
        // bRawData follows
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(IntPtr rawInput, uint command, IntPtr buffer, ref uint size, uint headerSize);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceInfo(IntPtr handle, uint command, IntPtr buffer, ref uint size);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceList(IntPtr devices, ref uint count, uint size);
}

/// <summary>
/// Low-level keyboard filter. It never injects: its only job is to swallow a
/// remote key's native press, either so the mapping can stand in for it or —
/// for keys published with an empty target — so the press simply never happens.
///
/// Only key-DOWNs are ever swallowed. Key-UP always passes through — a release
/// cannot make Windows act on its own (the key was never down) but it does
/// reach Raw Input carrying its device, which is the only device signal this
/// process can get. That is what makes "whoever spoke last owns the keys"
/// work and what keeps the physical keyboard safe.
/// </summary>
public sealed class RemoteKeyboardFilter : IDisposable
{
    private static readonly HookProc HookCallback = HookProcImpl;
    private static IntPtr _hook = IntPtr.Zero;

    // ---- Dedicated hook thread ----
    // LL hook callbacks are dispatched to the thread that installed the hook,
    // via that thread's message loop. Installing on the UI thread meant every
    // WebView2/WinForms burst delayed the callbacks — and Windows stops
    // waiting after ~300 ms: keys silently BYPASS the hook (observed live on
    // 2026-09-12: while GATT audio streamed and the UI was busy, the remote's
    // swallowed key flooded straight into the system). A dedicated thread that
    // does nothing but pump messages makes callback latency independent of
    // the UI.
    private Thread? _hookThread;
    private volatile uint _hookThreadId;
    private readonly ManualResetEventSlim _installDone = new(false);

    private static readonly object _lock = new();

    /// <summary>
    /// vk → replacement virtual keys; an EMPTY array means "swallow it, send
    /// nothing" (the voice key). The dictionary itself is empty while mapping
    /// is off, which disables the filter entirely.
    /// </summary>
    private static volatile Dictionary<uint, ushort[]> _targets = [];

    /// <summary>
    /// The tick of the last key event each side produced that this process
    /// could actually observe. Raw Input writes both; the hook also writes
    /// <see cref="_remoteAt"/> when it swallows, because a swallowed press
    /// never reaches Raw Input and would otherwise let the remote's ownership
    /// lapse in the middle of a navigation burst.
    /// </summary>
    private static long _remoteAt;
    private static long _localAt;

    /// <summary>Mapped keys currently held down, so auto-repeat does not re-map.</summary>
    private static readonly HashSet<uint> _held = [];
    /// <summary>When each mapped key last actually fired its target.</summary>
    private static readonly Dictionary<uint, long> _lastFiredAt = [];

    /// <summary>
    /// True while the voice key's press is being swallowed and its release has
    /// not been seen yet. Turns the ~32 Hz auto-repeat flood of a held key into
    /// exactly one down-transition and one up-transition for the voice session.
    /// </summary>
    private static bool _voiceDown;

    private const int WH_KEYBOARD_LL = 13;
    private const uint LLKHF_INJECTED = 0x10;
    private const uint LLKHF_UP = 0x80;

    /// <summary>
    /// Floor between two mappings of the same key. The remote reports a stuck
    /// or repeating key as a burst of presses, and it also emits spurious
    /// releases that would otherwise close a held press early; this makes a
    /// held key map once either way.
    /// </summary>
    private const long RepeatGuardMs = 400;

    /// <summary>After this long without remote activity the keyboard owns the
    /// mapped keys again. The hook runs before the physical key's own WM_INPUT
    /// can flip ownership, so the first physical press of a mapped key after
    /// putting the remote down would otherwise always be swallowed (observed:
    /// physical backspace typed "A"). Holding a remote key keeps refreshing
    /// _remoteAt, so long holds are unaffected.</summary>
    private const long RemoteIdleMs = 2_000;

    /// <summary>
    /// Raised with (vk, target) when the hook replaces a mapped key's native
    /// press. The mapping engine injects the target and reports it to the UI;
    /// the hook itself stays free of allocations and I/O.
    /// </summary>
    public static Action<uint, ushort[]>? Swallowed;

    /// <summary>
    /// Raised once per physical press/release of a swallow-only key (the voice
    /// key): (vk, isDown). Auto-repeat in between is not reported. The mapping
    /// engine turns these transitions into the voice-shortcut session.
    /// </summary>
    public static Action<uint, bool>? VoiceKeyTransition;

    public bool IsInstalled => _hook != IntPtr.Zero;

    /// <summary>Diagnostics: why the hook thread last failed (read after Install throws).</summary>
    public static string LastThreadError = "";

    public void Install()
    {
        if (_hook != IntPtr.Zero) return;
        _installDone.Reset();
        LastThreadError = "";
        _hookThread = new Thread(HookThreadMain)
        {
            IsBackground = true,
            Name = "KeyboardHook",
        };
        _hookThread.SetApartmentState(ApartmentState.STA);
        _hookThread.Start();
        // Generous deadline: on a cold start the runtime JITs WinForms +
        // WebView2 + this thread at once and 3 s proved too tight (observed
        // 2026-09-12: install "timed out" on a loaded machine).
        if (!_installDone.Wait(TimeSpan.FromSeconds(10)))
        {
            throw new InvalidOperationException(
                string.IsNullOrEmpty(LastThreadError) ? "键盘钩子线程启动超时。" : LastThreadError);
        }
        if (_hook == IntPtr.Zero)
            throw new InvalidOperationException(
                string.IsNullOrEmpty(LastThreadError) ? "无法安装低级键盘钩子。" : LastThreadError);

        // Self-test: inject a harmless F13 from a WORKER thread and wait for a
        // callback. It warms the whole callback path AND would catch a dead
        // hook — but it must NEVER throw: a false negative (the probe measured
        // main-thread-injected keys delivering late or not at all under load)
        // would otherwise disable an actually-working hook. The result is only
        // logged; HookInstalledOk tells the engine what happened.
        ArmSelfTest();
        var probe = Task.Run(() =>
        {
            try { KeyInjector.Tap(0x7C); } catch { } // VK_F13 — inert
        });
        probe.Wait(TimeSpan.FromSeconds(2));
        for (int i = 0; i < 30 && !SelfTestPassed; i++) Thread.Sleep(50);
        HookInstalledOk = SelfTestPassed;
    }

    /// <summary>False when the self-test could not confirm the hook; the hook
    /// itself is still installed either way.</summary>
    public static bool HookInstalledOk { get; private set; }

    private void HookThreadMain()
    {
        try
        {
            // A thread MUST have a message queue before the system can deliver
            // hook callbacks to it. GetMessage/PeekMessage create it lazily,
            // but SetWindowsHookEx on a queue-less thread is exactly the
            // "handle != 0, callbacks never fire" failure we measured. Create
            // it explicitly, then install.
            var dummy = new MSG();
            PeekMessage(out dummy, IntPtr.Zero, 0, 0, 0); // forces queue creation

            _hookThreadId = Kernel32.GetCurrentThreadId();
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, HookCallback, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
                LastThreadError = $"SetWindowsHookEx 失败 err={Marshal.GetLastWin32Error()}";
        }
        catch (Exception ex)
        {
            LastThreadError = "钩子线程异常：" + ex.Message;
        }
        finally
        {
            _installDone.Set();
        }
        if (_hook == IntPtr.Zero) return;
        // Pure message pump: this thread exists to service the hook and nothing
        // else. No UI, no I/O — callbacks stay fast and the hook stays alive.
        // GetMessage returns -1 on error, 0 on WM_QUIT, >0 otherwise. On -1 the
        // loop MUST be reported: a dead pump orphans the hook and every key
        // then passes through silently (observed 2026-09-12 16:xx build).
        while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        PumpExited?.Invoke($"钩子消息泵已退出（GetMessage err={Marshal.GetLastWin32Error()}）——钩子已失效，按键将全部透传");
    }

    /// <summary>Raised when the hook thread's message pump dies (hook orphaned).</summary>
    public static Action<string>? PumpExited;

    // ---- Self-test ----
    // 1 = armed (engine injected a probe key and waits), 2 = a callback arrived.
    private static int _hookAlivePhase;

    /// <summary>Arms the liveness marker before the self-test probe key.</summary>
    public static void ArmSelfTest() => Interlocked.Exchange(ref _hookAlivePhase, 1);

    /// <summary>True once any hook callback ran after <see cref="ArmSelfTest"/>.</summary>
    public static bool SelfTestPassed => Interlocked.CompareExchange(ref _hookAlivePhase, 0, 0) == 2;

    /// <summary>Publishes which virtual keys have a mapping and what to send instead.</summary>
    public static void SetRemoteKeyTargets(IEnumerable<KeyValuePair<uint, ushort[]>> targets)
    {
        _targets = new Dictionary<uint, ushort[]>(targets);
    }

    /// <summary>Forgets who spoke last. Called when mapping is switched off.</summary>
    public static void ClearOwnership()
    {
        lock (_lock)
        {
            _remoteAt = 0;
            _localAt = 0;
            _held.Clear();
            _lastFiredAt.Clear();
            _voiceDown = false;
        }
    }

    /// <summary>
    /// Raw Input reporting a key it could see — every release, plus every press
    /// that was not swallowed. This is the sole source of device ownership.
    ///
    /// A remote *press* is proof the remote is in use and takes ownership. A
    /// remote *release* only extends an ownership that is already held: the
    /// remote emits release chatter long after the user let go, and letting
    /// that chatter seize the keys would lock the physical keyboard out.
    /// </summary>
    public static void NoteObserved(bool fromRemote, bool up)
    {
        long now = Environment.TickCount64;
        lock (_lock)
        {
            if (!fromRemote) { _localAt = now; return; }
            if (!up || _remoteAt >= _localAt) _remoteAt = now;
        }
    }

    private static IntPtr HookProcImpl(int code, IntPtr wParam, IntPtr lParam)
    {
        // Any callback at all proves the pipeline is alive (self-test marker).
        Interlocked.CompareExchange(ref _hookAlivePhase, 2, 1);

        if (code < 0) return CallNextHookEx(_hook, code, wParam, lParam);

        var targets = _targets;
        if (targets.Count == 0) return CallNextHookEx(_hook, code, wParam, lParam);

        KBDLLHOOKSTRUCT info;
        try { info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam); }
        catch { return CallNextHookEx(_hook, code, wParam, lParam); }

        // Never touch injected input (ours or anyone else's).
        if ((info.flags & LLKHF_INJECTED) != 0)
            return CallNextHookEx(_hook, code, wParam, lParam);

        uint vk = info.vkCode;

        // Releases pass — EXCEPT the release of a press this filter swallowed
        // while the remote owned the keys (vk in _held AND remote still leads).
        // The paired down never reached the system, so that up is an orphan,
        // and some keys act on release alone (VK_APPS posts WM_CONTEXTMENU on
        // key-up): letting it through would resurrect the native action the
        // mapping just replaced.
        //
        // But if ownership has flipped back to the keyboard by the time the up
        // arrives, the swallowed down was a PHYSICAL key misattributed to the
        // remote (the hook runs before the key's own WM_INPUT updates
        // ownership). Swallowing its up too would double the damage: the
        // user's physical key would be erased AND the keyboard would lose its
        // way to reclaim ownership. So: remote leads → swallow; keyboard
        // leads → pass (NoteObserved already ran and restored balance).
        if ((info.flags & LLKHF_UP) != 0)
        {
            bool voiceUp = false;
            lock (_lock)
            {
                bool wasHeld = _held.Contains(vk);
                _held.Remove(vk);
                if (_targets.TryGetValue(vk, out var t) && t.Length == 0 && _voiceDown)
                {
                    _voiceDown = false;
                    voiceUp = true;
                }
                if (wasHeld && _remoteAt >= _localAt)
                {
                    // Remote still owns the keys: orphan release of a remote
                    // press. Swallow it — the mapping injected its own
                    // matching release inside KeyInjector.Tap.
                    return (IntPtr)1;
                }
            }
            if (voiceUp)
            {
                try { VoiceKeyTransition?.Invoke(vk, false); } catch { }
            }
            return CallNextHookEx(_hook, code, wParam, lParam);
        }

        if (!targets.TryGetValue(vk, out var target))
            return CallNextHookEx(_hook, code, wParam, lParam);

        // Swallow-only keys (the voice key) are swallowed UNCONDITIONALLY —
        // they are not gated on ownership. Their native key is pure side
        // effect (holding the voice key repeats VK_F5 ~32×/s): it damages
        // whatever window has focus (F5 = refresh/home) and never does good,
        // so leaking one "because the keyboard owns the keys right now" is
        // worse than the rare lost physical F5. Voice-key events also do not
        // touch global ownership: pressing it mid-typing must not steal the
        // mapped arrow keys from the keyboard.
        if (target.Length == 0)
        {
            bool voiceDown = false;
            lock (_lock)
            {
                // Collapse the ~32 Hz auto-repeat into one down-transition.
                if (!_voiceDown)
                {
                    _voiceDown = true;
                    voiceDown = true;
                }
            }
            if (voiceDown)
            {
                try { VoiceKeyTransition?.Invoke(vk, true); } catch { }
            }
            return (IntPtr)1;
        }

        long now = Environment.TickCount64;
        lock (_lock)
        {
            // Whoever produced the most recent observable key owns the mapped
            // keys. Equal ticks (fresh start, nothing seen yet) favour the
            // remote: the app exists to serve it.
            //
            // Ownership also decays: after RemoteIdleMs without any remote
            // activity the keyboard wins by default. Without this, the FIRST
            // physical press of a mapped key after putting the remote down is
            // always swallowed (its WM_INPUT — which would flip ownership —
            // arrives after this hook already ran), which read to the user as
            // "my keyboard's backspace types A". Holding a remote key keeps
            // refreshing _remoteAt, so long holds are unaffected.
            //
            // EXCEPTION — VK_APPS (the remote's Menu key): physical keyboards
            // practically never press it, so ownership decay must not apply —
            // otherwise the remote's menu press would leak through as the
            // native context menu instead of the mapped shortcut (observed
            // 2026-09-12 23:42).
            bool remoteActive = (_remoteAt >= _localAt && now - _remoteAt < RemoteIdleMs)
                || vk == 0x5D; // VK_APPS
            if (!remoteActive)
                return CallNextHookEx(_hook, code, wParam, lParam);
            _remoteAt = now;

            // Auto-repeat of a press already being handled: swallow it, but do
            // not fire the mapping again — holding "上" must not spray Win+D.
            if (_held.Contains(vk) && now - _lastFiredAt.GetValueOrDefault(vk) < RepeatGuardMs)
                return (IntPtr)1;

            _held.Add(vk);
            _lastFiredAt[vk] = now;
        }

        try { Swallowed?.Invoke(vk, target); } catch { /* never break the hook chain */ }
        return (IntPtr)1; // swallow the native press; the mapping replaces it
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
            // Posting WM_QUIT ends the pump; the thread exits on its own.
            if (_hookThreadId != 0) PostThreadMessage(_hookThreadId, 0x0012 /*WM_QUIT*/, IntPtr.Zero, IntPtr.Zero);
        }
        _hookThread = null;
        _hookThreadId = 0;
        SetRemoteKeyTargets([]);
        ClearOwnership();
        // NOT disposing _installDone: Install can legitimately be called again
        // after a Dispose (mapping off → on), and a disposed MRES throws.
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode, scanCode, flags, time;
        public ulong dwExtraInfo;
    }

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam, lParam;
        public uint time;
        public int ptX, ptY;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc proc, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    // NOTE: GetModuleHandle / GetMessage / PostThreadMessage exist ONLY as
    // A/W pairs. Declaring the bare name throws EntryPointNotFoundException
    // the first time the stub JITs — this exact bug cost an hour on
    // 2026-09-12 (the old code "worked" because GetModuleHandle(null) failing
    // inside the hook still passed NULL = current module).
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetMessage([Out] out MSG msg, IntPtr hwnd, uint min, uint max);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage([In] ref MSG msg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage([In] ref MSG msg);

    [DllImport("user32.dll")]
    private static extern bool PeekMessage([Out] out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);

    private static class Kernel32
    {
        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();
    }
}

/// <summary>Injects mapped keys. Down events on press; up events (reversed) on release.</summary>
public static class KeyInjector
{
    /// <summary>Stamped into dwExtraInfo so Raw Input can tell our own
    /// injections apart from real hardware (they would otherwise be read back
    /// as local keyboard activity).</summary>
    public const uint Signature = 0x4F524131; // "ORA1"

    /// <summary>
    /// Serialises injections. A tap is a down-burst, a short hold and an
    /// up-burst; if two of them overlapped, their modifiers would interleave
    /// and the system would see a combination nobody asked for (Win+Ctrl+A,
    /// say). Only ever taken off the UI thread — the keyboard hook itself never
    /// injects, so holding this while SendInput runs cannot deadlock the
    /// input thread.
    /// </summary>
    private static readonly object Gate = new();

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public KEYBDINPUT ki;
        public uint padding; // union padding (mouse is larger than keyboard)
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    private static bool NeedsExtended(ushort vk) => vk switch
    {
        0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28  // PgUp/PgDn/End/Home/arrows
        or 0x2D or 0x2E or 0x5D or 0x5B or 0x5C                       // Ins/Del/ContextMenu/Win keys
        or 0xA1 or 0xA3 or 0xA5                                       // RIGHT Shift/Ctrl/Alt — without
                                                                      // E0 the system sees the LEFT key
            => true,
        _ => false,
    };

    public static void Tap(params ushort[] vks)
    {
        lock (Gate)
        {
            var downs = vks.Select(vk => Input(vk, false)).ToArray();
            var ups = vks.Reverse().Select(vk => Input(vk, true)).ToArray();
            SendInput((uint)downs.Length, downs, Marshal.SizeOf<INPUT>());
            Thread.Sleep(15);
            SendInput((uint)ups.Length, ups, Marshal.SizeOf<INPUT>());
        }
    }

    /// <summary>Press and hold (for hold-mode voice shortcuts).</summary>
    public static void Press(params ushort[] vks)
    {
        lock (Gate)
        {
            var downs = vks.Select(vk => Input(vk, false)).ToArray();
            SendInput((uint)downs.Length, downs, Marshal.SizeOf<INPUT>());
        }
    }

    /// <summary>Release previously pressed keys (reverse order).</summary>
    public static void Release(params ushort[] vks)
    {
        lock (Gate)
        {
            var ups = vks.Reverse().Select(vk => Input(vk, true)).ToArray();
            SendInput((uint)ups.Length, ups, Marshal.SizeOf<INPUT>());
        }
    }

    private static INPUT Input(ushort vk, bool up)
    {
        return new INPUT
        {
            type = 1, // INPUT_KEYBOARD
            ki = new KEYBDINPUT
            {
                wVk = vk,
                dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (NeedsExtended(vk) ? KEYEVENTF_EXTENDEDKEY : 0),
                dwExtraInfo = new IntPtr((int)Signature),
            },
            padding = 0,
        };
    }
}
