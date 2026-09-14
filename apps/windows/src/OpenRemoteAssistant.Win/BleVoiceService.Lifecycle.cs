// SPDX-License-Identifier: GPL-3.0-only
// Windows BLE voice service, ported from RemoteVoiceService.swift (GPL-3.0-only).
// WinRT BluetoothLEDevice replaces CBCentralManager/CBPeripheral. The state
// machine (handshake, hold, receipt/deadline tokens, premature-start close)
// mirrors the macOS original; only the radio layer differs.

using System.Diagnostics;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Security.Cryptography;

namespace OpenRemoteAssistant.Win;

public sealed partial class RemoteVoiceService : IDisposable, IAsyncDisposable
{
    // ---- Callbacks (invoked on background threads; marshal in the GUI) ----
    public Action<RemoteVoiceStatus>? OnStatus;
    public Action<bool>? OnVoiceButton;
    /// <summary>GATT session reached Ready: voice-button events now come from here.</summary>
    public Action? OnSessionReady;
    /// <summary>GATT session ended: voice-button events fall back to the keyboard hook.</summary>
    public Action? OnSessionStopped;
    /// <summary>Audio routing diagnostics (sink counters etc.).</summary>
    public Action<string>? OnDiagnostics;
    /// <summary>Control chunks we don't natively parse (likely D-pad/other keys).</summary>
    public Action<byte[]>? OnUnknownControl;
    public Action<double>? OnLevel;
    public Action<RemoteDeviceCandidate[], string>? OnDiscovery;
    public Action<string>? OnLog;

    private readonly object _gate = new();     // protects mutable state below
    private VoicePhase _phase = VoicePhase.Idle;
    private VoiceSessionOptions? _configuration;
    private DeviceBinding? _targetBinding;
    private bool _discoveryPending;
    private RemoteDeviceCandidate[] _discoveryCandidates = [];
    private BluetoothLEDevice? _device;
    private GattDeviceService? _atvvService;
    private GattDeviceService? _infoService;
    private GattCharacteristic? _transmit;
    private GattCharacteristic? _control;
    private GattCharacteristic? _audio;
    private Rc003VoiceHandshake? _handshake;
    private Rc003VoiceHold? _hold;
    private Rc003VoicePcm? _pcm;
    private readonly Rc003AudioReceipt _receipt = new();
    private readonly List<byte> _earlyAudio = [];
    private IVoiceAudioSink? _output;
    private readonly Dictionary<string, string> _identityValues = [];
    private RemoteDevicePnpIdentity? _pnpIdentity;
    private RemoteDeviceIdentity? _verifiedIdentity;
    private bool _modelValidated;
    private bool _capsValidated;
    private bool _controlSubscribed;
    private bool _audioSubscribed;
    private CancellationTokenSource? _initCts;
    private CancellationTokenSource? _startCts;   // MIC_OPEN → START deadline (2 s)
    private CancellationTokenSource? _audioCts;   // inter-frame deadline (2 s)
    private CancellationTokenSource? _closeCts;   // CLOSE acknowledgement (0.35 s)
    private int _generation;
    private readonly Stopwatch _levelClock = new();
    private DateTime _lastLevelPublish;
    private long _lastLevelTicks;

    private static readonly Guid ServiceGuid = new(Rc003VoiceProtocol.ServiceUuid);
    private static readonly Guid TransmitGuid = new(Rc003VoiceProtocol.TransmitUuid);
    private static readonly Guid ControlGuid = new(Rc003VoiceProtocol.ControlUuid);
    private static readonly Guid AudioGuid = new(Rc003VoiceProtocol.AudioUuid);
    private static readonly Guid InformationGuid = Guid.Parse("0000180a-0000-1000-8000-00805f9b34fb");
    private static readonly (Guid Uuid, string Key)[] IdentityChars =
    [
        (Guid.Parse("00002a29-0000-1000-8000-00805f9b34fb"), "2A29"), // Manufacturer Name
        (Guid.Parse("00002a24-0000-1000-8000-00805f9b34fb"), "2A24"), // Model Number
        (Guid.Parse("00002a27-0000-1000-8000-00805f9b34fb"), "2A27"), // Hardware Revision
        (Guid.Parse("00002a26-0000-1000-8000-00805f9b34fb"), "2A26"), // Firmware Revision
        (Guid.Parse("00002a28-0000-1000-8000-00805f9b34fb"), "2A28"), // Software Revision
        (Guid.Parse("00002a50-0000-1000-8000-00805f9b34fb"), "2A50"), // PnP ID
    ];

    public RemoteVoiceStatus Status
    {
        get { lock (_gate) return BuildStatusLocked("…"); }
    }

    // ---------------------------------------------------------------- lifecycle

    public void ConfigureTarget(DeviceBinding? binding)
    {
        lock (_gate)
        {
            if (binding is { IsValid: true })
            {
                _targetBinding = binding;
            }
            else
            {
                _targetBinding = null;
            }
        }
    }

    /// <summary>Discovery-only session: connect, verify identity, no audio. One callback.</summary>
    public async Task DiscoverConnectedDevicesAsync()
    {
        lock (_gate)
        {
            if (_discoveryPending) return;
            _discoveryPending = true;
        }
        try
        {
            Log("查询：开始。");
            if (await CurrentPhaseAsync() != VoicePhase.Idle)
            {
                Log("查询：先停止旧会话。");
                await StopAsync("正在停止旧会话以查询已连接遥控器。");
            }
            Log($"查询：当前阶段 {_phase}，启动 BLE 连接流程。");
            await BeginAsync(new VoiceSessionOptions { IsDiscoveryProbe = true }, discovery: true);
            // Safety net: whatever path BeginAsync takes, the discovery flag
            // must not stay latched forever. Complete after 20s if still pending.
            _ = Task.Delay(TimeSpan.FromSeconds(20)).ContinueWith(_ =>
            {
                bool pending;
                lock (_gate) pending = _discoveryPending;
                if (pending)
                {
                    lock (_gate) _discoveryPending = false;
                    Log("查询：20 秒未完成，已重置查询状态；请重试。");
                    CompleteDiscovery([], "查询超时；请再次点击「查找遥控器」。");
                }
            }, TaskScheduler.Default);
        }
        catch (Exception ex)
        {
            Log($"查询异常：{ex.Message}");
            CompleteDiscovery([], $"查询异常：{ex.Message}");
        }
    }

    public async Task EnableAsync(VoiceSessionOptions options)
    {
        if (!options.ButtonEvents && !options.AudioEnabled)
        {
            await DisableAsync();
            return;
        }
        lock (_gate)
        {
            if (_targetBinding is not { IsValid: true })
            {
                Publish("请先显式查询并确认本机遥控器绑定；未连接设备。");
                return;
            }
        }
        if (await CurrentPhaseAsync() != VoicePhase.Idle)
            await StopAsync("正在安全重启语音服务。");
        await BeginAsync(options, discovery: false);
    }

    public async Task DisableAsync()
    {
        await StopAsync("语音服务已停止；未保存音频。");
    }

    private Task<VoicePhase> CurrentPhaseAsync() => Task.FromResult(_phase);

    private async Task BeginAsync(VoiceSessionOptions options, bool discovery)
    {
        if (discovery) options = new VoiceSessionOptions { IsDiscoveryProbe = true };
        CancellationTokenSource cts;
        lock (_gate)
        {
            if (_phase != VoicePhase.Idle)
            {
                // Never swallow the request: report it through the discovery
                // callback so the UI unblocks instead of waiting forever.
                if (discovery)
                {
                    Log($"查询被跳过：服务处于 {_phase} 状态。");
                    _ = Task.Run(() => CompleteDiscovery([], $"服务忙（{_phase}），请稍候重试。"));
                }
                return;
            }
            _generation++;
            CancelDeadlinesLocked();
            _initCts = new CancellationTokenSource();
            cts = _initCts;
            _configuration = options;
            _identityValues.Clear();
            _pnpIdentity = null;
            _verifiedIdentity = null;
            _handshake = new Rc003VoiceHandshake(options.AudioEnabled);
            _phase = VoicePhase.Connecting;
            _device = null;
            _atvvService = null;
            _infoService = null;
            _transmit = _control = _audio = null;
            _modelValidated = _capsValidated = _controlSubscribed = _audioSubscribed = false;
        }
        Publish(discovery
            ? "正在查询已连接遥控器的型号、版本和能力；不接收声音。"
            : "正在验证已确认绑定的遥控器；等待新的物理按键。");
        ArmInitDeadline(cts);
        try
        {
            // NOTE: no direct-address fast path here. Opening a device,
            // disposing it, and re-opening (as the old probe did) poisons the
            // GATT session — CCCD subscriptions stop delivering notifications.
            // The cached enumeration below is fast (~250ms) and clean.
            var matches = await RemoteFinder.FindConnectedRemotesAsync(cts.Token);
            string selected;
            try
            {
                selected = RemoteDiscoveryPolicy.Select(matches.Select(m => m.Address));
            }
            catch (DeviceSelectionException e)
            {
                await FailBeginAsync(cts, e.Message, discovery, []);
                return;
            }
            var chosen = matches.First(m => BluetoothAddress.Format(m.Address) == selected);
            await ConnectToAsync(chosen, cts, discovery);
        }
        catch (Exception ex)
        {
            Log($"BLE 初始化异常：{ex.Message}");
            await FailBeginAsync(cts, $"语音服务初始化失败：{ex.Message}", discovery, []);
        }
    }

    private static ulong ParseAddress(string text)
    {
        var hex = new string(text.Where(char.IsAsciiHexDigit).ToArray());
        return ulong.TryParse(hex, System.Globalization.NumberStyles.HexNumber,
            System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : 0;
    }

    private async Task ConnectToAsync(FoundRemote chosen, CancellationTokenSource cts, bool discovery)
    {
        var device = await BluetoothLEDevice.FromBluetoothAddressAsync(chosen.Address);
        if (device is null || cts.Token.IsCancellationRequested)
        {
            await FailBeginAsync(cts, "RC003-MS 语音连接失败；请确认遥控器在线后手动重试。", discovery, []);
            return;
        }
        lock (_gate)
        {
            _device = device;
            device.ConnectionStatusChanged += OnConnectionStatusChanged;
        }
        await SetupGattAsync(device, cts.Token, discovery);
    }

    private async Task FailBeginAsync(CancellationTokenSource cts, string message, bool discovery,
        RemoteDeviceCandidate[] candidates)
    {
        cts.Cancel();
        await StopAsync(message);
        if (discovery) CompleteDiscovery(candidates, message);
    }

    private void ArmInitDeadline(CancellationTokenSource cts)
    {
        var token = cts.Token;
        _ = Task.Delay(TimeSpan.FromSeconds(15), token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            if (Volatile.Read(ref _generation) >= 0 && _phase is VoicePhase.Connecting or VoicePhase.Handshaking)
                _ = StopAsync("语音服务初始化超时；未启动音频，请检查蓝牙权限并重试。");
        }, TaskScheduler.Default);
    }
}
