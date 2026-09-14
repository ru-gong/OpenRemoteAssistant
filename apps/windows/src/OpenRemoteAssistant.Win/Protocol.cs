// SPDX-License-Identifier: GPL-3.0-only
// Windows port of OpenRemoteAssistant (macOS original: ru-gong/OpenRemoteAssistant).
// Protocol constants and verification data ported from RemoteVoiceService.swift,
// DeviceProfile.swift and Models.swift of the GPL-3.0-only upstream source.

using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;

namespace OpenRemoteAssistant.Win;

/// <summary>RC003-MS ATVV voice protocol constants (GATT service AB5E0001-…).</summary>
public static class Rc003VoiceProtocol
{
    public const string ServiceUuid = "AB5E0001-5A21-4F05-BC7D-AF01F617B664";
    public const string TransmitUuid = "AB5E0002-5A21-4F05-BC7D-AF01F617B664";
    public const string AudioUuid = "AB5E0003-5A21-4F05-BC7D-AF01F617B664";
    public const string ControlUuid = "AB5E0004-5A21-4F05-BC7D-AF01F617B664";

    public static ReadOnlySpan<byte> GetCapabilities => [0x0A, 1, 0, 0, 3, 3];
    public static ReadOnlySpan<byte> MicrophoneOpen => [0x0C, 0];
    public static byte[] MicrophoneClose(byte session) => [0x0D, session];

    /// <summary>
    /// Exact responses observed from the supported RC003-MS sample running
    /// A.7.0.6. Both declare ATVV 1.0, 16 kHz codec 2 and 120-byte ADPCM frames.
    /// The remote has returned both the codec-bitmap fallback layout and the
    /// standard v1 layout across separate connections.
    /// </summary>
    private static readonly byte[][] SupportedCaps =
    [
        [0x0B, 1, 0, 0, 3, 0, 120, 0, 0],
        [0x0B, 1, 0, 2, 3, 0, 120, 0, 0],
    ];

    public const int SampleRate = 16_000;
    public const int FrameBytes = 120;
    public const int SamplesPerFrame = 240;

    public static bool ValidCapabilities(ReadOnlySpan<byte> data)
    {
        if (data.Length != 9) return false;
        foreach (var candidate in SupportedCaps)
        {
            if (candidate.AsSpan().SequenceEqual(data)) return true;
        }
        return false;
    }
}

/// <summary>
/// Matches the RC003-MS capability probe and the upstream RC003 capture flow:
/// explicitly requested, both notifications must be confirmed before GET_CAPS.
/// </summary>
public sealed class Rc003VoiceHandshake(bool audioEnabled)
{
    public enum Channel { Control, Audio }

    private readonly HashSet<Channel> _confirmed = [];
    public bool CapabilitiesRequested { get; private set; }

    public bool NotificationsReady =>
        _confirmed.Contains(Channel.Control) && (!audioEnabled || _confirmed.Contains(Channel.Audio));

    /// <summary>Returns true only once, when it is time to send GET_CAPS.</summary>
    public bool Confirm(Channel channel)
    {
        if (channel == Channel.Audio && !audioEnabled) return false;
        _confirmed.Add(channel);
        if (NotificationsReady && !CapabilitiesRequested)
        {
            CapabilitiesRequested = true;
            return true;
        }
        return false;
    }
}

/// <summary>
/// Receipt evidence counted only after a complete frame was successfully
/// enqueued. Deadline tokens invalidate old holds and older frames.
/// </summary>
public sealed class Rc003AudioReceipt
{
    public int Frames { get; private set; }
    public int Samples { get; private set; }
    private ulong _token;
    private bool _active;

    public ulong? DeadlineToken => _active ? _token : null;

    public void ResetHold() { Frames = 0; Samples = 0; _active = false; _token++; }
    public void StartStreaming() { _active = true; _token++; }

    /// <summary>Returns true for the first enqueued frame of a hold.</summary>
    public bool Enqueued(int sampleCount)
    {
        if (!_active || sampleCount <= 0) return false;
        bool first = Frames == 0;
        Frames++; Samples += sampleCount; _token++;
        return first;
    }

    public void End() { _active = false; _token++; }
    public bool ShouldTimeout(ulong expected) => _active && _token == expected;
}

public enum VoiceHoldActionKind
{
    Button, BeginHold, OpenMicrophone, StreamStarted, StreamEnded,
    CloseMicrophone, Failure
}

public readonly record struct VoiceHoldAction(
    VoiceHoldActionKind Kind,
    bool ButtonDown = false,
    byte Session = 0,
    string? FailureMessage = null)
{
    public static VoiceHoldAction Button(bool down) => new(VoiceHoldActionKind.Button, ButtonDown: down);
    public static VoiceHoldAction BeginHold => new(VoiceHoldActionKind.BeginHold);
    public static VoiceHoldAction OpenMicrophone => new(VoiceHoldActionKind.OpenMicrophone);
    public static VoiceHoldAction StreamStarted => new(VoiceHoldActionKind.StreamStarted);
    public static VoiceHoldAction StreamEnded => new(VoiceHoldActionKind.StreamEnded);
    public static VoiceHoldAction CloseMicrophone(byte session) => new(VoiceHoldActionKind.CloseMicrophone, Session: session);
    public static VoiceHoldAction Failure(string message) => new(VoiceHoldActionKind.Failure, FailureMessage: message);
}

/// <summary>
/// Pure control state. Every physical release returns to idle, permitting any
/// number of holds. Duplicate START/REQUEST never resets the current decoder.
/// Ported verbatim from RC003VoiceHold in RemoteVoiceService.swift.
/// </summary>
public sealed class Rc003VoiceHold(bool audioEnabled)
{
    private readonly bool _audioEnabled = audioEnabled;
    public bool Held { get; private set; }
    public bool Streaming { get; private set; }
    public byte SessionId { get; private set; }
    public bool MicrophoneMayBeOpen { get; private set; }

    public List<VoiceHoldAction> Control(ReadOnlySpan<byte> data)
    {
        if (data.IsEmpty || data.Length > 64)
            return [VoiceHoldAction.Failure("语音控制报告异常。")];
        switch (data[0])
        {
            case 0x08: // Button press
                if (Held) return [];
                Held = true;
                var result = new List<VoiceHoldAction> { VoiceHoldAction.Button(true), VoiceHoldAction.BeginHold };
                if (_audioEnabled) { MicrophoneMayBeOpen = true; result.Add(VoiceHoldAction.OpenMicrophone); }
                return result;
            case 0x04: // START / REQUEST
                if (data.Length < 4 || data[2] != 2)
                {
                    MicrophoneMayBeOpen = true;
                    if (data.Length >= 4) SessionId = data[3];
                    return [VoiceHoldAction.Failure("遥控器语音编码或会话标识异常。")];
                }
                if (Streaming) return data[3] == SessionId ? [] : [VoiceHoldAction.Failure("语音会话在按住期间改变。")];
                var actions = new List<VoiceHoldAction>();
                if (!Held) { Held = true; actions.Add(VoiceHoldAction.Button(true)); actions.Add(VoiceHoldAction.BeginHold); }
                SessionId = data[3];
                MicrophoneMayBeOpen = true; // A physical press can start the remote itself.
                Streaming = true;
                if (_audioEnabled) actions.Add(VoiceHoldAction.StreamStarted);
                return actions;
            case 0x00: // Button release / stop
                if (!Held && !MicrophoneMayBeOpen) return [];
                bool close = MicrophoneMayBeOpen;
                byte oldSession = SessionId;
                Held = false; Streaming = false; MicrophoneMayBeOpen = false; SessionId = 0;
                var release = new List<VoiceHoldAction> { VoiceHoldAction.Button(false), VoiceHoldAction.StreamEnded };
                if (close) release.Add(VoiceHoldAction.CloseMicrophone(oldSession));
                return release;
            default:
                // Unknown control chunk — may carry D-pad/other key codes.
                UnknownControl?.Invoke(data.ToArray());
                return [];
        }
    }

    /// <summary>Fired for control chunks we don't natively handle (e.g. D-pad).</summary>
    public static Action<byte[]>? UnknownControl;
}

public class VoiceProtocolException : Exception
{
    public VoiceProtocolException(string message) : base(message) { }
}

/// <summary>
/// One hold's bounded decoder. Replaced on each new hold; partial frames are
/// discarded on release or sync. Ported verbatim from RC003VoicePCM.
/// </summary>
public sealed class Rc003VoicePcm
{
    private readonly VoiceImaAdpcmDecoder _decoder = new();
    private readonly List<byte> _pending = [];
    private (int Predictor, int StepIndex)? _pendingSync;
    public int SampleCount { get; private set; }

    public void Synchronize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 7 || data.Length > 64 || data[0] != 0x0A || data[6] > 88)
            throw new VoiceProtocolException("invalid sync");
        _pending.Clear();
        _pendingSync = (BinaryPrimitives.ReadInt16BigEndian(data[4..]), data[6]);
    }

    public List<short[]> Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length > 4_096) throw new VoiceProtocolException("invalid packet");
        var frames = new List<short[]>();
        if (_pending.Count == 0 && data.Length >= Rc003VoiceProtocol.FrameBytes)
        {
            // Fast path: decode directly from the input span without copying.
            int offset = 0;
            while (data.Length - offset >= Rc003VoiceProtocol.FrameBytes)
            {
                ApplySync();
                checked
                {
                    try { SampleCount += Rc003VoiceProtocol.SamplesPerFrame; }
                    catch (OverflowException) { throw new VoiceProtocolException("sample count overflow"); }
                }
                frames.Add(_decoder.Decode(data.Slice(offset, Rc003VoiceProtocol.FrameBytes)));
                offset += Rc003VoiceProtocol.FrameBytes;
            }
            var remainder = data[offset..].ToArray();
            _pending.AddRange(remainder);
            return frames;
        }
        _pending.AddRange(data);
        int consumed = 0;
        while (_pending.Count - consumed >= Rc003VoiceProtocol.FrameBytes)
        {
            ApplySync();
            checked
            {
                try { SampleCount += Rc003VoiceProtocol.SamplesPerFrame; }
                catch (OverflowException) { throw new VoiceProtocolException("sample count overflow"); }
            }
            frames.Add(_decoder.Decode(CollectionsMarshal.AsSpan(_pending).Slice(consumed, Rc003VoiceProtocol.FrameBytes)));
            consumed += Rc003VoiceProtocol.FrameBytes;
        }
        if (consumed > 0) _pending.RemoveRange(0, consumed);
        return frames;
    }

    private void ApplySync()
    {
        if (_pendingSync is { } sync)
        {
            _decoder.Reset(sync.Predictor, sync.StepIndex);
            _pendingSync = null;
        }
    }
}

/// <summary>High-nibble-first IMA ADPCM decoder, ported verbatim from
/// VoiceIMAADPCMDecoder (itself adapted from nijez/open-voice-bridge).</summary>
public sealed class VoiceImaAdpcmDecoder
{
    private static readonly int[] Steps =
    [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,
        97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
        1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,
        5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,
        27086,29794,32767
    ];
    private static readonly int[] Indices = [-1,-1,-1,-1,2,4,6,8];

    private int _predictor;
    private int _stepIndex;

    public void Reset(int value = 0, int index = 0)
    {
        _predictor = Math.Clamp(value, -32_768, 32_767);
        _stepIndex = Math.Clamp(index, 0, 88);
    }

    public short[] Decode(ReadOnlySpan<byte> bytes)
    {
        var result = new short[bytes.Length * 2];
        int i = 0;
        foreach (byte b in bytes)
        {
            result[i++] = Nibble(b >> 4);
            result[i++] = Nibble(b & 15);
        }
        return result;
    }

    private short Nibble(int value)
    {
        int step = Steps[_stepIndex];
        int delta = step >> 3;
        if ((value & 1) != 0) delta += step >> 2;
        if ((value & 2) != 0) delta += step >> 1;
        if ((value & 4) != 0) delta += step;
        _predictor = Math.Clamp(_predictor + ((value & 8) != 0 ? -delta : delta), -32_768, 32_767);
        _stepIndex = Math.Clamp(_stepIndex + Indices[value & 7], 0, 88);
        return (short)_predictor;
    }
}

/// <summary>Bluetooth Device Information Service PnP ID (characteristic 0x2A50).</summary>
public readonly record struct RemoteDevicePnpIdentity(byte VendorIdSource, ushort VendorId, ushort ProductId, ushort ProductVersion)
{
    public static RemoteDevicePnpIdentity? Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length != 7) return null;
        return new RemoteDevicePnpIdentity(
            data[0],
            BinaryPrimitives.ReadUInt16LittleEndian(data[1..]),
            BinaryPrimitives.ReadUInt16LittleEndian(data[3..]),
            BinaryPrimitives.ReadUInt16LittleEndian(data[5..]));
    }
}

/// <summary>Measured compatibility tuple, not a claim about every revision sold
/// under the same marketing name.</summary>
public sealed record RemoteDeviceIdentity(
    string Manufacturer, string Model, string Hardware, string Firmware, string Software,
    RemoteDevicePnpIdentity? Pnp)
{
    public static RemoteDeviceIdentity? TryFromGatt(
        string? manufacturer, string? model, string? hardware, string? firmware, string? software,
        RemoteDevicePnpIdentity? pnp)
    {
        // GATT strings are trimmed of whitespace/control characters; empty means unknown.
        static string? Clean(string? s) => s is null ? null : new string(s.Where(c => !char.IsWhiteSpace(c) && !char.IsControl(c)).ToArray());
        var m = Clean(manufacturer); var mo = Clean(model); var h = Clean(hardware);
        var f = Clean(firmware); var sw = Clean(software);
        if (string.IsNullOrEmpty(m) || string.IsNullOrEmpty(mo) || string.IsNullOrEmpty(h)
            || string.IsNullOrEmpty(f) || string.IsNullOrEmpty(sw)) return null;
        return new RemoteDeviceIdentity(m, mo, h, f, sw, pnp);
    }
}

public sealed record DeviceProfile(string Id, RemoteDeviceIdentity Identity)
{
    public const ushort VendorId = 0x2717;
    public const ushort ProductId = 0x32B8;

    /// <summary>The sole active/supported profile. Hardware reports model RC003;
    /// RC003-MS is the product name shown to users.</summary>
    public static DeviceProfile Rc003Ms { get; } = new("xiaomi-rc003-ms-v2-2671", new RemoteDeviceIdentity(
        "MIOM", "RC003", "V2.0", "2671", "A.7.0.6",
        new RemoteDevicePnpIdentity(1, 0x2717, 0x32B8, 0x00A4)));

    public bool Accepts(RemoteDeviceIdentity value) => value == Identity;
}

/// <summary>Host-local observations only. Name is intentionally absent from
/// selection: a Bluetooth name is not device identity.</summary>
public static class RemoteDiscoveryPolicy
{
    public static string Select(IEnumerable<ulong> addresses, ulong? boundAddress = null)
    {
        var unique = new HashSet<ulong>(addresses);
        if (unique.Count == 0) throw new DeviceSelectionException(DeviceSelectionError.Missing);
        if (unique.Count > 1) throw new DeviceSelectionException(DeviceSelectionError.Ambiguous);
        var selected = unique.First();
        if (boundAddress is { } bound && selected != bound)
            throw new DeviceSelectionException(DeviceSelectionError.DifferentDevice);
        return BluetoothAddress.Format(selected);
    }

    public static string Describe(DeviceSelectionError error) => error switch
    {
        DeviceSelectionError.Missing => "未发现已连接的目标遥控器；请先在系统蓝牙设置配对连接。",
        DeviceSelectionError.Ambiguous => "检测到多只候选遥控器；请断开其他遥控器后重新查询，不会自动选择。",
        DeviceSelectionError.DifferentDevice => "已连接设备与本机绑定不同；请重新确认绑定，不会自动替换。",
        _ => "设备选择异常。",
    };
}

public enum DeviceSelectionError { Missing, Ambiguous, DifferentDevice }

public sealed class DeviceSelectionException(DeviceSelectionError error)
    : Exception(RemoteDiscoveryPolicy.Describe(error))
{
    public DeviceSelectionError Error { get; } = error;
}

public static class BluetoothAddress
{
    public static string Format(ulong address) =>
        string.Join(":", Enumerable.Range(0, 6).Select(i => $"{(address >> ((5 - i) * 8)) & 0xFF:X2}"));

    public static string Normalize(string text)
    {
        var hex = new string(text.Where(char.IsAsciiHexDigit).ToArray());
        if (hex.Length != 12) throw new FormatException($"invalid Bluetooth address: {text}");
        return string.Join(":", Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2).ToUpperInvariant()));
    }
}

/// <summary>Minimal JSON helpers used by the binding store (no external packages).</summary>
public static class MiniJson
{
    public static string Escape(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    public static string Quote(string s) => $"\"{Escape(s)}\"";
}
