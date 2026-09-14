// SPDX-License-Identifier: GPL-3.0-only
// Stop path, teardown, connection monitoring, status publishing, disposal.

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;

namespace OpenRemoteAssistant.Win;

public sealed partial class RemoteVoiceService
{
    /// <summary>Idempotent stop. Sends MIC_CLOSE when the microphone may be open.</summary>
    public async Task StopAsync(string message)
    {
        CancellationTokenSource? initCts;
        lock (_gate)
        {
            if (_phase == VoicePhase.Idle) { Publish(message); return; }
            if (_phase == VoicePhase.Stopping) return;
            _phase = VoicePhase.Stopping;
            initCts = _initCts;
        }
        initCts?.Cancel();
        CancelDeadlinesLocked();

        bool needsClose;
        byte session;
        IVoiceAudioSink? output;
        lock (_gate)
        {
            needsClose = _hold?.MicrophoneMayBeOpen == true;
            session = _hold?.SessionId ?? 0;
            output = _output;
            bool held = _hold?.Held == true;
            _hold = null;
            _pcm = null;
            _earlyAudio.Clear();
            if (held && _configuration?.ButtonEvents == true) OnVoiceButton?.Invoke(false);
        }

        if (needsClose)
        {
            var command = Rc003VoiceProtocol.MicrophoneClose(session);
            await WriteAsync(command);
        }
        output?.StopImmediately();
        try { output?.Dispose(); } catch { }
        lock (_gate) _output = null;

        FinishStop(message);
    }

    private void FinishStop(string message)
    {
        bool wasDiscovery;
        RemoteDeviceCandidate[] candidates;
        lock (_gate)
        {
            wasDiscovery = _discoveryPending;
            candidates = _discoveryCandidates;
            UnsubscribeAllLocked();
            _phase = VoicePhase.Idle;
            _generation++;
            _configuration = null;
            _modelValidated = false;
            _capsValidated = false;
            _controlSubscribed = false;
            _audioSubscribed = false;
            _handshake = null;
            _identityValues.Clear();
            _pnpIdentity = null;
            _verifiedIdentity = null;
            _discoveryCandidates = [];
        }
        // Session is gone: the keyboard hook resumes reporting the voice key.
        OnSessionStopped?.Invoke();
        Publish(message);
        if (wasDiscovery) CompleteDiscovery(candidates, message);
    }

    private void UnsubscribeAllLocked()
    {
        // Caller holds _gate.
        if (_control is { } control)
        {
            try { control.ValueChanged -= OnControlChanged; } catch { }
            if (_controlSubscribed)
            {
                try { _ = control.WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.None); } catch { }
            }
        }
        if (_audio is { } audio)
        {
            try { audio.ValueChanged -= OnAudioChanged; } catch { }
            if (_audioSubscribed)
            {
                try { _ = audio.WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.None); } catch { }
            }
        }
        if (_device is { } device)
        {
            try { device.ConnectionStatusChanged -= OnConnectionStatusChanged; } catch { }
        }
        try { _atvvService?.Dispose(); } catch { }
        try { _infoService?.Dispose(); } catch { }
        try { _device?.Dispose(); } catch { }
        _atvvService = null;
        _infoService = null;
        _device = null;
        _transmit = null;
        _control = null;
        _audio = null;
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus != BluetoothConnectionStatus.Disconnected) return;
        VoicePhase phase;
        lock (_gate) phase = _phase;
        if (phase is VoicePhase.Idle or VoicePhase.Stopping) return;
        _ = StopAsync("遥控器已断开；语音服务已停止，重连后需手动启用。");
    }

    private void CancelDeadlinesLocked()
    {
        // Caller holds _gate.
        _initCts?.Cancel();
        _initCts = null;
        _startCts?.Cancel();
        _startCts = null;
        _audioCts?.Cancel();
        _audioCts = null;
        _closeCts?.Cancel();
        _closeCts = null;
    }

    private void CompleteDiscovery(RemoteDeviceCandidate[] candidates, string message)
    {
        bool pending;
        lock (_gate)
        {
            pending = _discoveryPending;
            _discoveryPending = false;
        }
        if (pending) OnDiscovery?.Invoke(candidates, message);
    }

    private RemoteVoiceStatus BuildStatusLocked(string message)
    {
        bool active = _phase is VoicePhase.Connecting or VoicePhase.Handshaking or VoicePhase.Ready;
        bool discoveryActive = _discoveryPending && active;
        return new RemoteVoiceStatus
        {
            IsEnabled = !_discoveryPending && active,
            IsDiscovering = discoveryActive,
            IsReady = _phase == VoicePhase.Ready,
            IsStreaming = _phase == VoicePhase.Ready && _hold?.Streaming == true && _configuration?.AudioEnabled == true,
            AudioFrames = _receipt.Frames,
            AudioSamples = _receipt.Samples,
            Message = string.IsNullOrEmpty(message) ? "…" : message,
        };
    }

    private void Publish(string message)
    {
        RemoteVoiceStatus status;
        lock (_gate) status = BuildStatusLocked(message);
        OnStatus?.Invoke(status);
        OnLog?.Invoke($"[状态] {message}");
    }

    private void Log(string message) => OnLog?.Invoke(message);

    public void Dispose() => _ = StopAsync("语音服务已停止；未保存音频。");

    public async ValueTask DisposeAsync() => await StopAsync("语音服务已停止；未保存音频。");
}
