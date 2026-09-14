// SPDX-License-Identifier: GPL-3.0-only
// Notification handlers: caps validation, hold state machine execution,
// audio decode/route, premature-start close, deadlines.

using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Security.Cryptography;

namespace OpenRemoteAssistant.Win;

public sealed partial class RemoteVoiceService
{
    private void OnControlChanged(GattCharacteristic sender, object args)
    {
        try
        {
            var value = ((GattValueChangedEventArgs)args).CharacteristicValue;
            var data = DataToArray(value);
            HandleControlData(data);
        }
        catch (Exception ex) { Log($"控制通知处理异常：{ex.Message}"); }
    }

    private void OnAudioChanged(GattCharacteristic sender, object args)
        => HandleAudioData(((GattValueChangedEventArgs)args).CharacteristicValue is { } v ? DataToArray(v) : []);

    private void HandleControlData(byte[] data)
    {
        if (data.Length == 0) return;
        // Capability response
        if (data[0] == 0x0B)
        {
            bool modelOk, capsRequested;
            lock (_gate) { modelOk = _modelValidated; capsRequested = _handshake?.CapabilitiesRequested == true; }
            if (!modelOk || !capsRequested || !Rc003VoiceProtocol.ValidCapabilities(data))
            {
                _ = StopAsync("遥控器未通过 16 kHz / 120 字节帧语音能力校验。");
                return;
            }
            lock (_gate)
            {
                if (_capsValidated) return;
                _capsValidated = true;
            }
            BecomeReady();
            return;
        }
        VoicePhase phase;
        lock (_gate) phase = _phase;
        if (phase != VoicePhase.Ready)
        {
            // A physical press can make RC003 start itself while setup is
            // unfinished. Do not accept its audio; request shutdown + close.
            if (data[0] == 0x04)
            {
                var premature = new Rc003VoiceHold(audioEnabled: false);
                premature.Control(data);
                lock (_gate) _hold = premature;
                _ = StopAsync("遥控器在初始化完成前开始语音；已请求关麦，请就绪后再按语音键。");
            }
            return;
        }
        bool audioEnabled;
        lock (_gate) audioEnabled = _configuration?.AudioEnabled == true;
        // Sync frame (predictor/stepIndex restart)
        if (data[0] == 0x0A && audioEnabled)
        {
            bool held;
            lock (_gate) held = _hold?.Held == true;
            if (held)
            {
                var pcm = _pcm;
                if (pcm is not null)
                {
                    try { pcm.Synchronize(data); _earlyAudio.Clear(); }
                    catch (VoiceProtocolException) { _ = StopAsync("语音同步参数异常；已停止推流。"); }
                }
            }
            return;
        }
        List<VoiceHoldAction> actions;
        byte[]? unknown = null;
        Rc003VoiceHold.UnknownControl = payload => unknown = payload;
        lock (_gate)
        {
            if (_hold is not { } hold) return;
            actions = hold.Control(data);
        }
        if (unknown is not null) OnUnknownControl?.Invoke(unknown);
        ExecuteActions(actions);
    }

    private void HandleAudioData(byte[] data)
    {
        bool eligible;
        Rc003VoicePcm? pcm;
        lock (_gate)
        {
            eligible = _phase == VoicePhase.Ready && _configuration?.AudioEnabled == true && _hold?.Held == true;
            pcm = _pcm;
        }
        if (!eligible || pcm is null) return;
        bool streaming;
        lock (_gate) streaming = _hold?.Streaming == true;
        if (streaming) DecodeAndRoute(data);
        else
        {
            lock (_gate)
            {
                if (data.Length > 4_096 || _earlyAudio.Count + data.Length > 1_920)
                {
                    _ = StopAsync("语音开始前缓冲异常；已停止。");
                    return;
                }
                _earlyAudio.AddRange(data);
            }
        }
    }

    private void BecomeReady()
    {
        bool discovery, audioEnabled;
        RemoteDeviceIdentity? identity;
        string deviceName;
        string address;
        lock (_gate)
        {
            if (_phase != VoicePhase.Handshaking || !_capsValidated || _verifiedIdentity is null) return;
            discovery = _configuration?.IsDiscoveryProbe ?? false;
            audioEnabled = _configuration?.AudioEnabled == true;
            identity = _verifiedIdentity;
            deviceName = _device?.Name ?? "小米蓝牙语音遥控器";
            address = BluetoothAddress.Format(_device?.BluetoothAddress ?? 0);
        }
        if (discovery)
        {
            lock (_gate)
            {
                _discoveryCandidates = [new RemoteDeviceCandidate(address, deviceName, identity!, DeviceProfile.Rc003Ms.Id)];
            }
            _ = StopAsync("发现一个支持的 RC003-MS（设备自报 RC003）；请确认只连接了这一只且是手中的设备，再保存本机绑定。");
            return;
        }
        lock (_gate)
        {
            _phase = VoicePhase.Ready;
            _initCts?.Cancel();
            _initCts = null;
            _hold = new Rc003VoiceHold(audioEnabled);
        }
        // GATT is now the authoritative source of voice-button events; the
        // keyboard-hook path must stand down while this session lives.
        OnSessionReady?.Invoke();
        Publish(audioEnabled
            ? "遥控器已连接；按住语音键开始接收音频，松手停止；不设固定录音时长。"
            : "语音键监听已就绪；不订阅音频、不发送开麦命令。");
    }

    private void ExecuteActions(List<VoiceHoldAction> actions)
    {
        foreach (var action in actions)
        {
            VoicePhase phase;
            lock (_gate) phase = _phase;
            if (phase != VoicePhase.Ready) return;
            switch (action.Kind)
            {
                case VoiceHoldActionKind.Button:
                    bool report;
                    lock (_gate) report = _configuration?.ButtonEvents == true;
                    if (report) OnVoiceButton?.Invoke(action.ButtonDown);
                    break;
                case VoiceHoldActionKind.BeginHold:
                    lock (_gate) { _pcm = new Rc003VoicePcm(); _earlyAudio.Clear(); _receipt.ResetHold(); }
                    ResetLevelClock();
                    bool audioOn;
                    lock (_gate) audioOn = _configuration?.AudioEnabled == true;
                    Publish(audioOn ? "语音键已按下，等待遥控器开麦。" : "语音键已按下。");
                    break;
                case VoiceHoldActionKind.OpenMicrophone:
                    // Each hold gets a fresh sink: the previous one was drained
                    // and disposed on release (mirrors upstream per-hold output).
                    TeardownOutput();
                    if (!PrepareOutput())
                    {
                        _ = StopAsync("无法准备虚拟音频或发送开麦命令；已停止。");
                        return;
                    }
                    _ = WriteWithStopOnFailureAsync(
                        Rc003VoiceProtocol.MicrophoneOpen.ToArray(),
                        "无法准备虚拟音频或发送开麦命令；已停止。");
                    ArmStartDeadline();
                    break;
                case VoiceHoldActionKind.StreamStarted:
                    CancelDeadline(ref _startCts);
                    // A bare physical START (no REQUEST) still needs an output.
                    TeardownOutput();
                    PrepareOutput();
                    lock (_gate) _receipt.StartStreaming();
                    ArmAudioDeadline();
                    lock (_gate)
                        Publish("遥控器已开麦，等待音频数据；松开后最多 0.75 秒送完已入队尾音。"
                                + (_output is null ? "（音频输出：无！）" : $"（音频输出：{_output.Name}）"));
                    byte[] early;
                    lock (_gate) { early = [.. _earlyAudio]; _earlyAudio.Clear(); }
                    if (early.Length > 0) DecodeAndRoute(early);
                    break;
                case VoiceHoldActionKind.StreamEnded:
                    CancelDeadline(ref _startCts);
                    IVoiceAudioSink? output;
                    lock (_gate) output = _output;
                    // Report routing counters while the sink is still alive.
                    switch (output)
                    {
                        case WaveOutSink wo:
                            OnDiagnostics?.Invoke($"waveOut 统计：open={wo.OpenResult} dev={wo.MatchedDeviceIndex}({wo.MatchedDeviceName}) enqueuedFrames={wo.EnqueuedFrames} writtenBuffers={wo.WrittenBuffers}");
                            break;
                        case WasapiOutSink ws:
                            OnDiagnostics?.Invoke($"wasapi 统计：endpoint={ws.EndpointName} enqueuedFrames={ws.EnqueuedFrames} bytes={ws.EnqueuedBytes}");
                            break;
                    }
                    lock (_gate)
                    {
                        _pcm = null;
                        _earlyAudio.Clear();
                        output = _output;
                    }
                    output?.FinishAfterDraining();
                    lock (_gate) _receipt.End();
                    ResetLevelClock();
                    OnLevel?.Invoke(0);
                    Publish("遥控器已关麦；已入队尾音会在后台送完（最长 0.75 秒）。");
                    break;
                case VoiceHoldActionKind.CloseMicrophone:
                    _ = WriteAsync(Rc003VoiceProtocol.MicrophoneClose(action.Session).ToArray());
                    break;                case VoiceHoldActionKind.Failure:
                    _ = StopAsync(action.FailureMessage ?? "语音失败。");
                    return;
            }
        }
    }

    private async Task WriteWithStopOnFailureAsync(byte[] data, string failureMessage)
    {
        if (!await WriteAsync(data)) _ = StopAsync(failureMessage);
    }

    private void TeardownOutput()
    {
        IVoiceAudioSink? output;
        lock (_gate) { output = _output; _output = null; }
        if (output is null) return;
        try { output.StopImmediately(); } catch { }
        try { output.Dispose(); } catch { }
    }

    private bool PrepareOutput()
    {
        Func<IVoiceAudioSink>? factory;
        lock (_gate) factory = _configuration?.AudioSinkFactory;
        if (factory is null) return false;
        if (_output is not null) return true;
        var sink = factory();
        if (!sink.Prepare()) { sink.Dispose(); return false; }
        lock (_gate) _output = sink;
        return true;
    }

    private void DecodeAndRoute(byte[] data)
    {
        Rc003VoicePcm? pcm;
        lock (_gate) pcm = _pcm;
        if (pcm is null) return;
        try
        {
            var frames = pcm.Decode(data);
            foreach (var frame in frames) EnqueueDecodedFrame(frame);
        }
        catch (VoiceProtocolException)
        {
            _ = StopAsync("语音数据异常或采样计数溢出；已停止服务。");
        }
    }

    private void EnqueueDecodedFrame(short[] frame)
    {
        IVoiceAudioSink? output;
        lock (_gate) output = _output;
        if (output is null) return;
        if (!output.Enqueue(frame))
        {
            _ = StopAsync("虚拟音频输出失败。已停止，不回退到扬声器。");
            return;
        }
        bool first;
        lock (_gate) first = _receipt.Enqueued(frame.Length);
        ArmAudioDeadline();
        if (first) Publish("已收到遥控器音频；松开语音键停止。");
        PublishLevel(frame);
    }

    private void PublishLevel(short[] frame)
    {
        long now = _levelClock.ElapsedMilliseconds;
        if (Interlocked.Read(ref _lastLevelTicks) + 50 <= now)
        {
            Interlocked.Exchange(ref _lastLevelTicks, now);
            double square = 0;
            foreach (var s in frame) { double v = s / 32768.0; square += v * v; }
            OnLevel?.Invoke(Math.Min(1, Math.Sqrt(square / frame.Length)));
        }
    }

    private void ResetLevelClock()
    {
        _levelClock.Restart();
        Interlocked.Exchange(ref _lastLevelTicks, 0);
    }

    private void ArmStartDeadline()
    {
        CancelDeadline(ref _startCts);
        var cts = new CancellationTokenSource();
        _startCts = cts;
        _ = Task.Delay(TimeSpan.FromSeconds(2), cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            _ = StopAsync("遥控器未确认语音开始；已请求关麦并停止服务。");
        }, TaskScheduler.Default);
    }

    private void ArmAudioDeadline()
    {
        ulong? token;
        lock (_gate) token = _receipt.DeadlineToken;
        if (token is null) return;
        CancelDeadline(ref _audioCts);
        var cts = new CancellationTokenSource();
        _audioCts = cts;
        ulong expected = token.Value;
        _ = Task.Delay(TimeSpan.FromSeconds(2), cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            bool timeout;
            int frames;
            lock (_gate) { timeout = _receipt.ShouldTimeout(expected); frames = _receipt.Frames; }
            if (timeout)
                _ = StopAsync(frames == 0
                    ? "遥控器已开麦，但 2 秒内未收到完整音频数据；已请求关麦并停止服务，请重新连接后重试。"
                    : "连续 2 秒未收到新的完整音频数据；已请求关麦并停止服务，请重新连接后重试。");
        }, TaskScheduler.Default);
    }

    private void CancelDeadline(ref CancellationTokenSource? field)
    {
        field?.Cancel();
        field?.Dispose();
        field = null;
    }
}
