// SPDX-License-Identifier: GPL-3.0-only
// WebView2-hosted modern UI. The HTML/CSS/JS front-end (wwwroot) talks to
// this host through window.chrome.webview.postMessage → Host.DispatchAsync.
// Every message: {type: "...", ...payload}; every reply: {type: "...:reply", ok, data}.

using Microsoft.Web.WebView2.Core;
using System.ComponentModel;
using System.Text;
using System.Text.Json;

namespace OpenRemoteAssistant.Win;

public sealed class UiBridge : IDisposable
{
    private readonly RemoteVoiceService _voice;
    private readonly BindingStore _binding;
    private readonly MappingStore _mapping;
    private readonly MappingEngine _engine;
    private readonly Func<string> _recordingsFolder;
    private readonly Action<string> _setRecordingsFolder;
    private Microsoft.Web.WebView2.WinForms.WebView2? _webView;

    public event Action<string>? Log;

    private Action<string>? _logSink;
    public void SetLogSink(Action<string> sink) => _logSink = sink;

    public UiBridge(
        RemoteVoiceService voice,
        BindingStore binding,
        MappingStore mapping,
        MappingEngine engine,
        Func<string> recordingsFolder,
        Action<string> setRecordingsFolder)
    {
        _voice = voice;
        _binding = binding;
        _mapping = mapping;
        _engine = engine;
        _recordingsFolder = recordingsFolder;
        _setRecordingsFolder = setRecordingsFolder;
        _settingsFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenRemoteAssistant", "settings.json");
        LoadSettings();

        _voice.OnStatus = s => Push("voice-status", new
        {
            message = s.Message,
            ready = s.IsReady,
            streaming = s.IsStreaming,
            discovering = s.IsDiscovering,
            frames = s.AudioFrames,
            samples = s.AudioSamples,
        });
        _voice.OnLevel = l => Push("level", new { level = l });
        _voice.OnDiscovery = (candidates, message) =>
        {
            // Save the binding and configure the service for it (the old
            // MainForm did this in its own discovery handler; keep parity).
            if (candidates.Length == 1 && candidates[0].IsSupported)
            {
                var c = candidates[0];
                _binding.Save(new DeviceBinding
                {
                    ProfileId = DeviceProfile.Rc003Ms.Id,
                    BluetoothAddress = c.BluetoothAddress,
                    Identity = c.Identity,
                    ConfirmedAt = DateTime.Now.ToString("o"),
                    SingleRemoteConfirmed = true,
                });
                _voice.ConfigureTarget(_binding.Current);
            }
            Push("discovery", new
            {
                message,
                count = candidates.Length,
                candidates = candidates.Select(c => new
                {
                    address = c.BluetoothAddress,
                    name = c.Name,
                    model = c.Identity.Model,
                    hardware = c.Identity.Hardware,
                    firmware = c.Identity.Firmware,
                    software = c.Identity.Software,
                    manufacturer = c.Identity.Manufacturer,
                }).ToArray(),
            });
            Push("initial-state", SnapshotState()); // refresh bound state in UI
        };
        // GATT button events are authoritative while the voice session is up;
        // flag the engine so the keyboard-hook path stands down (otherwise one
        // physical press fires HandleVoiceButton twice — toggle would open and
        // instantly close). The same handler serves both paths.
        _voice.OnSessionReady = () => _engine.SetGattVoiceActive(true);
        _voice.OnSessionStopped = () => _engine.SetGattVoiceActive(false);
        _voice.OnDiagnostics = m => _logSink?.Invoke($"[voice诊断] {m}");
        _voice.OnVoiceButton = down => { try { _engine.HandleVoiceButton(down); } catch { } Push("voice-button", new { down }); };
        _voice.OnLog = m =>
        {
            // Mirror service logs into the on-disk app.log for diagnosability.
            _logSink?.Invoke($"[voice] {m}");
            Push("log", new { text = $"[voice] {m}" });
        };
        _engine.OnMapped = (button, description) =>
        {
            Push("mapped", new { button = button.Id(), title = button.Title(), target = description });
            Push("log", new { text = $"[映射] {button.Title()} → {description}" });
        };
        _engine.OnVoiceModeChanged = mode =>
        {
            Push("voice-mode-changed", new { mode, target = _mapping.VoiceTarget });
        };
    }

    private TaskScheduler? _uiScheduler;

    /// <summary>
    /// Dedicated STA-like thread for the whole BLE session lifetime. WinRT
    /// GATT notifications only fire on the context that opened the session;
    /// the WebView2/WinForms UI context starves them, a plain dedicated
    /// thread with a real message pump delivers them (proven by headless).
    /// </summary>
    private readonly Lazy<TaskScheduler> _bleScheduler = new(() =>
    {
        var started = new TaskCompletionSource<TaskScheduler>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            // WindowsFormsSynchronizationContext + Application.Run gives this
            // thread a real message pump that Post() marshals into — the same
            // environment where BLE notifications provably fire (headless).
            var context = new WindowsFormsSynchronizationContext();
            SynchronizationContext.SetSynchronizationContext(context);
            started.SetResult(TaskScheduler.FromCurrentSynchronizationContext());
            try { Application.Run(); } catch { /* exiting */ }
        });
        thread.IsBackground = true;
        thread.Name = "BleSession";
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return started.Task.GetAwaiter().GetResult();
    });

    public void ShutdownBleThread()
    {
        if (_bleScheduler.IsValueCreated)
        {
            try
            {
                var ctx = _bleScheduler.Value;
                _ = Task.Factory.StartNew(() => Application.ExitThread(),
                    CancellationToken.None, TaskCreationOptions.None, ctx);
            }
            catch { }
        }
    }

    public void Attach(Microsoft.Web.WebView2.WinForms.WebView2 webView)
    {
        _webView = webView;
        _uiScheduler = TaskScheduler.FromCurrentSynchronizationContext();
        // Restore any previous binding so "连接语音" works right after launch.
        if (_binding.Current is { IsValid: true } restored)
            _voice.ConfigureTarget(restored);
        webView.CoreWebView2InitializationCompleted += (s, e) =>
        {
            if (!e.IsSuccess) { _logSink?.Invoke($"WebView2 初始化失败：{e.InitializationException?.Message}"); return; }
            webView.CoreWebView2.WebMessageReceived += OnWebMessage;
            Push("initial-state", SnapshotState());
            _logSink?.Invoke("界面就绪。");
            // Auto-connect the voice session when a binding is already saved:
            // without this the remote mic is dead until someone clicks
            // 「连接语音」 after every launch, and the audio-routing chain
            // (program → virtual cable → speech software) silently does
            // nothing.
            if (_binding.Current is { IsValid: true })
            {
                _logSink?.Invoke("[桥接] 检测到已有绑定，自动连接语音服务…");
                _ = Task.Factory.StartNew(async () =>
                {
                    try { await EnableVoiceAsync(); }
                    catch (Exception ex) { _logSink?.Invoke($"[语音] 自动连接失败：{ex.Message}"); }
                }, CancellationToken.None, TaskCreationOptions.None, _bleScheduler.Value);
            }
        };
    }

    private Dictionary<string, object?> SnapshotState() => new()
    {
        ["enabled"] = _mapping.Enabled,
        ["playback"] = PlaybackEnabled,
        ["record"] = RecordEnabled,
        ["playbackDevice"] = PlaybackOutputDevice,
        ["cableInstalled"] = IsVirtualCableInstalled(),
        ["cableDriverPresent"] = IsCableDriverRegistered(),
        ["voiceMode"] = _mapping.VoiceMode.ToString().ToLowerInvariant(),
        ["voiceTarget"] = _mapping.VoiceTarget,
        ["recordingsFolder"] = _recordingsFolder(),
        ["buttons"] = RemoteButtonExtensions.All.ToDictionary(
            b => b.Id(),
            b => new { title = b.Title(), target = _mapping.Get(b)?.Describe() ?? "", vks = _mapping.Get(b)?.VirtualKeys }),
        ["bound"] = _binding.Current is { IsValid: true } ? new
        {
            name = "小米蓝牙语音遥控器",
            address = _binding.Current.BluetoothAddress,
            model = _binding.Current.Identity?.Model,
        } : null,
    };

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            // Clone survives doc disposal so the async dispatch can read payload.
            var root = doc.RootElement.Clone();
            var type = root.TryGetProperty("type", out var t) ? t.GetString() : null;
            if (type is null) return;
            if (type == "js-error")
            {
                var msgText = root.TryGetProperty("message", out var m) ? m.GetString() : "?";
                _logSink?.Invoke($"[前端] {msgText}");
                return;
            }
            _logSink?.Invoke($"[桥接] 收到界面消息：{type}");
            // WinRT BLE notifications have thread affinity to the context that
            // started the session. GUI runs them on the WebView2/WinForms sync
            // context where GATTValueChanged stops firing; headless (classic
            // STA + console pump) works. Run the session on a dedicated
            // dedicated-thread scheduler that mimics the working environment.
            var scheduler = _bleScheduler.Value;
            _ = Task.Factory.StartNew(async () =>
            {
                try
                {
                    var data = await DispatchAsync(type, root);
                    Push($"{type}:reply", new { ok = true, data });
                }
                catch (Exception ex)
                {
                    Push($"{type}:reply", new { ok = false, error = ex.Message });
                    _logSink?.Invoke($"[界面] {type} 失败：{ex.Message}");
                }
            }, CancellationToken.None, TaskCreationOptions.None, scheduler);
        }
        catch (Exception ex)
        {
            Log?.Invoke($"界面消息处理异常：{ex.Message}");
        }
    }

    private async Task<object?> DispatchAsync(string type, JsonElement payload)
    {
        switch (type)
        {
            case "get-state":
                return SnapshotState();

            case "discover":
                _logSink?.Invoke("[桥接] 开始查询遥控器…");
                await _voice.DiscoverConnectedDevicesAsync();
                _logSink?.Invoke("[桥接] 查询调用已返回。");
                return null;

            case "connect-voice":
                await EnableVoiceAsync();
                return null;

            case "stop-voice":
                await _voice.DisableAsync();
                return null;

            case "set-button-mapping":
                {
                    var buttonId = payload.GetProperty("button").GetString()!;
                    var target = payload.TryGetProperty("vks", out var vksEl) && vksEl.ValueKind == JsonValueKind.Array
                        ? vksEl.EnumerateArray().Select(v => (ushort)v.GetUInt16()).ToArray()
                        : null;
                    var button = RemoteButtonExtensions.All.FirstOrDefault(b => b.Id() == buttonId);
                    // "microphone" is not settable: MappingStore.Set refuses it,
                    // so this returns the (always empty) describe unchanged.
                    if (button.Id() == buttonId)
                        _mapping.Set(button, target);
                    return new { describe = _mapping.Get(button)?.Describe() ?? "" };
                }

            case "set-mapping-enabled":
                _mapping.SetEnabled(payload.GetProperty("enabled").GetBoolean());
                // Enabling mapping after startup must arm the keyboard filter too.
                if (_mapping.Enabled) _engine.EnsureStarted();
                return null;

            case "reset-mappings":
                _mapping.ResetToDefaults();
                _logSink?.Invoke("[桥接] 按键映射已恢复默认（全部未映射，语音快捷键 F2）。");
                return SnapshotState();

            case "set-voice-shortcut":
                {
                    var mode = payload.GetProperty("mode").GetString() switch
                    {
                        "hold" => VoiceShortcutMode.Hold,
                        "holdtap" => VoiceShortcutMode.HoldTap,
                        _ => VoiceShortcutMode.Toggle, // voice shortcut is always on; default = toggle
                    };
                    ushort[]? vks = null;
                    if (payload.TryGetProperty("vks", out var vksEl) && vksEl.ValueKind == JsonValueKind.Array)
                        vks = vksEl.EnumerateArray().Select(v => (ushort)v.GetUInt16()).ToArray();
                    if (vks is null || vks.Length == 0) vks = [0x71]; // default F2
                    _mapping.SetVoiceShortcut(mode, vks);
                    return null;
                }

            case "cycle-voice-mode":
                _engine.CycleVoiceMode();
                return new { mode = _mapping.VoiceMode.ToString().ToLowerInvariant(), target = _mapping.VoiceTarget };

            case "set-playback":
                PlaybackEnabled = payload.GetProperty("enabled").GetBoolean();
                SaveSettings();
                // The audio sink is chosen when the session starts; a change
                // mid-session needs a session restart to take effect.
                await RestartVoiceSessionIfActiveAsync();
                return null;

            case "set-record":
                RecordEnabled = payload.GetProperty("enabled").GetBoolean();
                SaveSettings();
                await RestartVoiceSessionIfActiveAsync();
                return null;

            // Audio routing: list render endpoints, pick one (virtual cable),
            // and report whether a VB-Cable-like device exists.
            case "list-output-devices":
                {
                    // isVirtual is computed here rather than in the UI: the
                    // picker entry is the main defence against choosing a real
                    // speaker and then wondering why nothing reaches the voice
                    // software.
                    var devices = WaveOutSink.EnumerateOutputDevices()
                        .Select(d => new
                        {
                            index = d.Index,
                            name = d.Name,
                            isVirtual = LooksVirtualAudio(d.Name),
                        })
                        .ToArray();
                    return new
                    {
                        devices,
                        selected = PlaybackOutputDevice,
                        selectedIsVirtual = PlaybackOutputDevice is { } sel && LooksVirtualAudio(sel),
                        resolution = DescribeResolution(PlaybackOutputDevice),
                        cableInstalled = IsVirtualCableInstalled(),
                        cableDriverPresent = IsCableDriverRegistered(),
                    };
                }

            // End-to-end audio path self-check: enumerates every endpoint with
            // its real state, pushes a test tone through the production sink,
            // and measures what arrives on the cable's recording endpoint.
            case "audio-check":
                {
                    var result = await Task.Run(() => AudioCheck.Run(PlaybackOutputDevice));
                    var path = WriteAudioCheckReport(result.Report);
                    _logSink?.Invoke($"[自检] {result.Verdict}");
                    if (path is not null) _logSink?.Invoke($"[自检] 完整报告已写入 {path}");
                    return new
                    {
                        verdict = result.Verdict,
                        passed = result.Passed,
                        report = result.Report,
                        path,
                    };
                }

            case "set-output-device":
                {
                    string? name = payload.TryGetProperty("name", out var n) ? n.GetString() : null;
                    PlaybackOutputDevice = string.IsNullOrWhiteSpace(name) ? null : name;
                    SaveSettings();
                    await RestartVoiceSessionIfActiveAsync();
                    return new { selected = PlaybackOutputDevice };
                }

            // One-click helper for the virtual sound card: launches VB-Audio's
            // own setup (documented silent switches) so other software gets a
            // microphone endpoint. Needs elevation, and a reboot to take effect.
            case "open-cable-website":
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "https://vb-audio.com/Cable/",
                    UseShellExecute = true,
                });
                return new { opened = true };

            case "install-virtual-cable":
                return InstallVirtualCable();

            case "set-recordings-folder":
                {
                    var folder = payload.GetProperty("folder").GetString() ?? "";
                    if (!string.IsNullOrWhiteSpace(folder)) _setRecordingsFolder(folder);
                    return new { folder = _recordingsFolder() };
                }

            case "pick-folder":
                {
                    string? picked = null;
                    var t = new TaskCompletionSource<string?>();
                    _uiThread?.Invoke(new MethodInvoker(() =>
                    {
                        using var dialog = new FolderBrowserDialog { UseDescriptionForTitle = true, Description = "选择录音保存目录" };
                        t.SetResult(dialog.ShowDialog() == DialogResult.OK ? dialog.SelectedPath : null);
                    }), null);
                    picked = await t.Task;
                    if (!string.IsNullOrEmpty(picked)) _setRecordingsFolder(picked);
                    return new { folder = _recordingsFolder() };
                }

            case "open-folder":
                System.Diagnostics.Process.Start("explorer.exe", _recordingsFolder());
                return null;

            default:
                throw new InvalidOperationException($"未知消息类型 {type}");
        }
    }

    private ISynchronizeInvoke? _uiThread;

    public void SetUiThread(ISynchronizeInvoke invoker) => _uiThread = invoker;

    /// <summary>
    /// Builds the sink chain from current settings and (re)starts the voice
    /// session. Also used to hot-apply playback/record/device changes: the
    /// sink factory is captured when the session starts, so changing any of
    /// them mid-session requires a session restart.
    /// Output routing prefers WASAPI (stable real-time streaming into a
    /// virtual cable); if the requested device fragment does not resolve,
    /// falls back to the legacy winmm path.
    /// </summary>
    private async Task EnableVoiceAsync()
    {
        var playback = PlaybackEnabled;
        var record = RecordEnabled;
        var folder = _recordingsFolder();
        var outDev = PlaybackOutputDevice;
        // Log the resolution up front: if a configured device silently falls
        // back to the speakers, this line is the only place it shows.
        if (playback) _logSink?.Invoke($"[声卡] 回放输出：{DescribeResolution(outDev)}");
        var factory = new Func<IVoiceAudioSink>(() =>
        {
            var sinks = new List<IVoiceAudioSink>();
            if (playback)
            {
                // WASAPI by default; keep winmm as a manual fallback.
                sinks.Add(new WasapiOutSink(ResolveWasapiFragment(outDev)));
            }
            if (record) sinks.Add(new WavRecordSink(folder));
            return sinks.Count == 0 ? new NullSink()
                : sinks.Count == 1 ? sinks[0]
                : new CompositeSink(sinks.ToArray());
        });
        await _voice.EnableAsync(new VoiceSessionOptions
        {
            ButtonEvents = true,
            AudioSinkFactory = factory,
        });
    }

    /// <summary>Maps the persisted winmm-style device name to a WASAPI
    /// friendly-name fragment. "扬声器 (VB-Audio Virtual Cable)" → the
    /// renderer endpoint whose name contains it; default output → null.</summary>
    private static string? ResolveWasapiFragment(string? winmmName)
    {
        if (string.IsNullOrWhiteSpace(winmmName)) return null;
        // winmm names wrap the endpoint friendly name: "扬声器 (VB-Audio Virtual Cable)".
        // The WASAPI friendly name is "扬声器 (VB-Audio Virtual Cable)" too for
        // this driver — match on the parenthesised driver part which is stable.
        int open = winmmName.LastIndexOf('(');
        int close = winmmName.LastIndexOf(')');
        if (open >= 0 && close > open)
            return winmmName.Substring(open + 1, close - open - 1); // "VB-Audio Virtual Cable"
        return winmmName;
    }

    /// <summary>
    /// Same fragment extraction as the playback path uses, exposed so the
    /// self-check reports exactly what the sink will match on rather than a
    /// re-implementation that could drift.
    /// </summary>
    public static string? WasapiFragmentFor(string? deviceName) => ResolveWasapiFragment(deviceName);

    /// <summary>Human-readable outcome of resolving the configured device, so a
    /// silent fall back to the speakers can never go unnoticed again.</summary>
    private static string DescribeResolution(string? winmmName)
    {
        if (string.IsNullOrWhiteSpace(winmmName)) return "未指定，使用系统默认输出设备。";
        var fragment = ResolveWasapiFragment(winmmName);
        if (fragment is null) return "未指定，使用系统默认输出设备。";
        try
        {
            using var en = new NAudio.CoreAudioApi.MMDeviceEnumerator();
            var active = en.EnumerateAudioEndPoints(NAudio.CoreAudioApi.DataFlow.Render,
                NAudio.CoreAudioApi.DeviceState.Active).ToList();
            var hit = active.FirstOrDefault(d =>
                d.FriendlyName.Contains(fragment, StringComparison.OrdinalIgnoreCase));
            if (hit is not null) return $"已匹配到端点「{hit.FriendlyName}」。";
            var anyState = en.EnumerateAudioEndPoints(NAudio.CoreAudioApi.DataFlow.Render,
                NAudio.CoreAudioApi.DeviceState.All).Any(d =>
                d.FriendlyName.Contains(fragment, StringComparison.OrdinalIgnoreCase));
            return anyState
                ? $"设备「{fragment}」存在但不在「在用」状态——音频会回退到系统默认设备。装完虚拟声卡通常需要重启电脑。"
                : $"设备「{fragment}」在系统里找不到——音频会回退到系统默认设备。";
        }
        catch (Exception ex)
        {
            return $"解析失败（{ex.Message}）。";
        }
    }

    /// <summary>
    /// True for endpoints that are a virtual loopback cable rather than a real
    /// speaker. Deliberately narrower than "virtual": the remote-desktop audio
    /// device also calls itself virtual but carries no audio we can route.
    /// </summary>
    public static bool LooksVirtualAudio(string name) =>
        name.Contains("CABLE", StringComparison.OrdinalIgnoreCase)
        || name.Contains("VB-Audio", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Virtual Audio", StringComparison.OrdinalIgnoreCase);

    /// <summary>Persists the self-check report so a user can attach it to a
    /// support message without digging through the log window.</summary>
    private static string? WriteAudioCheckReport(string report)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenRemoteAssistant");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "音频自检报告.txt");
            File.WriteAllText(path, report, new System.Text.UTF8Encoding(true));
            return path;
        }
        catch { return null; }
    }

    /// <summary>Restarts the GATT session if it is currently enabled, so a
    /// new sink configuration takes effect without user action.</summary>
    private async Task RestartVoiceSessionIfActiveAsync()
    {
        if (_voice.Status is { IsEnabled: true } or { IsReady: true })
        {
            _logSink?.Invoke("[语音] 设置已更改，自动重启语音会话以应用。");
            await EnableVoiceAsync();
        }
    }

    public bool PlaybackEnabled { get; private set; }
    public bool RecordEnabled { get; private set; }
    /// <summary>winmm output device name for playback routing (virtual cable).</summary>
    public string? PlaybackOutputDevice { get; private set; }
    private readonly string _settingsFile;

    /// <summary>True when a VB-Audio Virtual Cable (or compatible) render
    /// endpoint exists — i.e. the virtual sound card is installed.</summary>
    public static bool IsVirtualCableInstalled() =>
        WaveOutSink.EnumerateOutputDevices().Any(d =>
            d.Name.Contains("CABLE", StringComparison.OrdinalIgnoreCase)
            || d.Name.Contains("Virtual Audio", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// True when the VB-Cable driver is registered in the audio class registry
    /// key but its render endpoint is not live yet. The vendor's installer
    /// writes the device entry immediately, while the endpoint only appears
    /// after a reboot — so this separates "installed, reboot pending" from
    /// "not installed", which the winmm enumeration alone cannot tell apart.
    /// </summary>
    public static bool IsCableDriverRegistered()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                @"SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}");
            if (key is null) return false;
            foreach (var name in key.GetSubKeyNames())
            {
                if (!name.StartsWith("00", StringComparison.Ordinal)) continue;
                using var sub = key.OpenSubKey(name);
                if (sub?.GetValue("DriverDesc") is string desc
                    && desc.Contains("CABLE", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        catch { }
        return false;
    }

    /// <summary>Finds the VB-Cable package that ships unmodified beside the
    /// application (vbcable\VBCABLE_Setup_x64.exe).</summary>
    private static string? LocateCableSetup()
    {
        var root = AppContext.BaseDirectory;
        foreach (var candidate in new[]
                 {
                     Path.Combine(root, "vbcable", "VBCABLE_Setup_x64.exe"),
                     Path.Combine(root, "VBCABLE_Setup_x64.exe"),
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>
    /// Starts VB-Audio's own setup with its documented silent switches
    /// (-h -i) under elevation. The package is redistributed as-is; this method
    /// only launches the vendor's installer rather than installing a driver
    /// itself. The endpoint needs a reboot before it can be used.
    /// </summary>
    private object InstallVirtualCable()
    {
        if (IsVirtualCableInstalled())
            return new { launched = false, registered = true, message = "已检测到虚拟声卡，无需安装。" };

        var setup = LocateCableSetup();
        if (setup is null)
            return new { launched = false, registered = false, message = "未找到随附的虚拟声卡安装包（缺少 vbcable 目录）。" };

        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = setup,
            Arguments = "-h -i",
            WorkingDirectory = Path.GetDirectoryName(setup)!,
            UseShellExecute = true,
            Verb = "runas", // elevation — a UAC prompt is expected
        };

        try
        {
            System.Diagnostics.Process.Start(psi);
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return new { launched = false, registered = false, message = "已取消管理员授权，虚拟声卡未安装。" };
        }
        catch (Exception ex)
        {
            return new { launched = false, registered = false, message = $"无法启动安装程序：{ex.Message}" };
        }

        _logSink?.Invoke("[声卡] 已启动 VB-Cable 静默安装；完成后必须重启电脑才会出现 CABLE 设备。");

        // The installer takes tens of seconds and the UI bridge times out at
        // 30 s, so this returns immediately and lets the front-end poll
        // list-output-devices for the registry entry. This watcher only logs.
        _ = Task.Run(async () =>
        {
            try
            {
                for (int i = 0; i < 180; i++)
                {
                    await Task.Delay(1000);
                    if (IsCableDriverRegistered() || IsVirtualCableInstalled())
                    {
                        _logSink?.Invoke("[声卡] 虚拟声卡已安装，重启电脑后生效。");
                        return;
                    }
                }
                _logSink?.Invoke("[声卡] 安装程序已结束，但未检测到驱动；请确认在管理员授权弹窗中选择了「是」。");
            }
            catch { }
        });

        return new
        {
            launched = true,
            message = "安装程序已启动，请在管理员授权弹窗中选择「是」；装好后需要重启电脑。",
        };
    }

    private void LoadSettings()
    {
        try
        {
            if (File.Exists(_settingsFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(_settingsFile));
                if (doc.RootElement.TryGetProperty("playback", out var p)) PlaybackEnabled = p.GetBoolean();
                if (doc.RootElement.TryGetProperty("record", out var r)) RecordEnabled = r.GetBoolean();
                if (doc.RootElement.TryGetProperty("playbackDevice", out var d)
                    && d.ValueKind == JsonValueKind.String)
                    PlaybackOutputDevice = d.GetString();
                return;
            }
        }
        catch { }
        // Sensible defaults for the primary use case (voice input tool):
        // no speaker playback, no WAV files.
        PlaybackEnabled = false;
        RecordEnabled = false;
    }

    private void SaveSettings()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_settingsFile)!);
            File.WriteAllText(_settingsFile,
                JsonSerializer.Serialize(new
                {
                    playback = PlaybackEnabled,
                    record = RecordEnabled,
                    playbackDevice = PlaybackOutputDevice,
                },
                    new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    /// <summary>Front-end → host toggle for realtime playback.</summary>
    public void SetPlayback(bool enabled) => PlaybackEnabled = enabled;

    private void Push(string type, object? data)
    {
        var webView = _webView;
        if (webView is null) return;
        string json;
        try
        {
            json = JsonSerializer.Serialize(new { type, data }, new JsonSerializerOptions
            {
                Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            });
        }
        catch { return; }
        // Service callbacks fire on the dedicated BLE thread; CoreWebView2 is
        // strictly UI-thread. Marshal the post onto the captured UI scheduler.
        var uiScheduler = _uiScheduler;
        void Post()
        {
            try
            {
                if (webView.CoreWebView2 is not null)
                    webView.CoreWebView2.PostWebMessageAsJson(json);
            }
            catch { /* webview not ready */ }
        }
        if (uiScheduler is not null && uiScheduler != TaskScheduler.Current)
            _ = Task.Factory.StartNew(Post, CancellationToken.None, TaskCreationOptions.None, uiScheduler);
        else
            Post();
    }

    public void Dispose() { }
}
