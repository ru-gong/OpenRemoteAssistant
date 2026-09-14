// SPDX-License-Identifier: GPL-3.0-only
// Status types for the Windows BLE voice service.

namespace OpenRemoteAssistant.Win;

public enum VoicePhase { Idle, Connecting, Handshaking, Ready, Stopping }

public sealed class RemoteVoiceStatus
{
    public bool IsEnabled { get; init; }
    public bool IsDiscovering { get; init; }
    public bool IsReady { get; init; }
    public bool IsStreaming { get; init; }
    public int AudioFrames { get; init; }
    public int AudioSamples { get; init; }
    public bool HasReceivedAudio => IsReady && AudioFrames > 0;
    public string Message { get; init; } = "语音服务未启用。";
}

public sealed record RemoteDeviceCandidate(
    string BluetoothAddress, string Name, RemoteDeviceIdentity Identity, string ProfileId)
{
    public bool IsSupported => ProfileId == DeviceProfile.Rc003Ms.Id && DeviceProfile.Rc003Ms.Accepts(Identity);
}

/// <summary>Serializable binding (host-local only).</summary>
public sealed class DeviceBinding
{
    public string ProfileId { get; set; } = "";
    public string BluetoothAddress { get; set; } = "";
    public RemoteDeviceIdentity? Identity { get; set; }
    public string ConfirmedAt { get; set; } = "";
    public bool SingleRemoteConfirmed { get; set; }
    public bool IsValid =>
        ProfileId == DeviceProfile.Rc003Ms.Id
        && Identity is not null && DeviceProfile.Rc003Ms.Accepts(Identity)
        && SingleRemoteConfirmed
        && !string.IsNullOrEmpty(BluetoothAddress);
}

public sealed class VoiceSessionOptions
{
    /// <summary>Report voice-button events to the caller (HID mapping hook).</summary>
    public bool ButtonEvents { get; init; }
    /// <summary>Sink factory used when audio is enabled; null = voice button only.</summary>
    public Func<IVoiceAudioSink>? AudioSinkFactory { get; init; }
    /// <summary>Discovery probe: verify identity, then stop without audio.</summary>
    public bool IsDiscoveryProbe { get; init; }
    public bool AudioEnabled => AudioSinkFactory is not null;
}
