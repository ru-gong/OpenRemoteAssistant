// SPDX-License-Identifier: GPL-3.0-only
// GATT setup + handshake: discover services/characteristics, read identity,
// verify RC003-MS, subscribe CCCD (control → audio), send GET_CAPS.

using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Security.Cryptography;

namespace OpenRemoteAssistant.Win;

public sealed partial class RemoteVoiceService
{
    private async Task SetupGattAsync(BluetoothLEDevice device, CancellationToken token, bool discovery)
    {
        SetPhase(VoicePhase.Handshaking);
        // Cached reads are instant and reliable; over-the-air (Uncached)
        // discovery regularly fails with Unreachable/ProtocolError when the
        // stack is busy. Prefer the cache, retry over the air only if empty.
        var infoResult = await device.GetGattServicesForUuidAsync(InformationGuid, BluetoothCacheMode.Cached);
        if (infoResult.Status != GattCommunicationStatus.Success || infoResult.Services.Count == 0)
            infoResult = await device.GetGattServicesForUuidAsync(InformationGuid, BluetoothCacheMode.Uncached);
        var voiceResult = await device.GetGattServicesForUuidAsync(ServiceGuid, BluetoothCacheMode.Cached);
        if (voiceResult.Status != GattCommunicationStatus.Success || voiceResult.Services.Count == 0)
            voiceResult = await device.GetGattServicesForUuidAsync(ServiceGuid, BluetoothCacheMode.Uncached);
        Log($"GATT 服务发现：info={infoResult.Status}/{infoResult.Services.Count} voice={voiceResult.Status}/{voiceResult.Services.Count}");
        if (token.IsCancellationRequested) return;
        if (infoResult.Status != GattCommunicationStatus.Success
            || voiceResult.Status != GattCommunicationStatus.Success
            || infoResult.Services.Count == 0 || voiceResult.Services.Count == 0)
        {
            await FailAsync("遥控器缺少设备信息或 ATVV 语音服务。", discovery);
            return;
        }
        var infoService = infoResult.Services[0];
        var atvvService = voiceResult.Services[0];
        lock (_gate) { _infoService = infoService; _atvvService = atvvService; }

        // ---- Read identity characteristics (2A29/2A24/2A27/2A26/2A28/2A50) ----
        string? manufacturer = null, model = null, hardware = null, firmware = null, software = null;
        RemoteDevicePnpIdentity? pnp = null;
        foreach (var (uuid, _) in IdentityChars)
        {
            if (token.IsCancellationRequested) return;
            var chars = await infoService.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Cached);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0)
                chars = await infoService.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Uncached);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0)
            {
                await FailAsync("设备缺少可读取的型号/硬件/固件/软件信息，无法验证支持组合。", discovery);
                return;
            }
            var characteristic = chars.Characteristics[0];
            var read = await characteristic.ReadValueAsync(BluetoothCacheMode.Cached);
            if (read.Status != GattCommunicationStatus.Success)
                read = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
            if (read.Status != GattCommunicationStatus.Success)
            {
                await FailAsync("无法读取遥控器身份特征。", discovery);
                return;
            }
            var data = DataToArray(read.Value);
            if (uuid == PnpGuid)
            {
                pnp = RemoteDevicePnpIdentity.Parse(data);
                if (pnp is null)
                {
                    await FailAsync("遥控器 PnP 身份信息格式异常；未启用服务。", discovery);
                    return;
                }
            }
            else
            {
                if (data.Length > 256)
                {
                    await FailAsync("遥控器身份信息格式异常；未启用服务。", discovery);
                    return;
                }
                var text = CleanIdentityText(data);
                if (string.IsNullOrEmpty(text))
                {
                    await FailAsync("遥控器身份信息为空；未启用服务。", discovery);
                    return;
                }
                if (uuid == ManufacturerGuid) manufacturer = text;
                else if (uuid == ModelGuid) model = text;
                else if (uuid == HardwareGuid) hardware = text;
                else if (uuid == FirmwareGuid) firmware = text;
                else if (uuid == SoftwareGuid) software = text;
            }
        }

        // ---- Verify identity ----
        var identity = RemoteDeviceIdentity.TryFromGatt(manufacturer, model, hardware, firmware, software, pnp);
        bool bindingOk;
        lock (_gate)
        {
            bindingOk = _targetBinding is null
                || (_targetBinding.Identity == identity
                    && _targetBinding.BluetoothAddress == BluetoothAddress.Format(device.BluetoothAddress));
        }
        if (identity is null || !DeviceProfile.Rc003Ms.Accepts(identity) || !bindingOk)
        {
            await FailAsync("遥控器型号、版本或 PnP 身份未通过 RC003-MS 支持列表；未启用服务。", discovery);
            return;
        }
        lock (_gate) { _verifiedIdentity = identity; _modelValidated = true; }

        // ---- Discover ATVV characteristics ----
        var atvvChars = await atvvService.GetCharacteristicsAsync(BluetoothCacheMode.Cached);
        if (atvvChars.Status != GattCommunicationStatus.Success || atvvChars.Characteristics.Count == 0)
            atvvChars = await atvvService.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);
        Log($"ATVV 特征发现：{atvvChars.Status}/{atvvChars.Characteristics.Count}");
        if (atvvChars.Status != GattCommunicationStatus.Success)
        {
            await FailAsync("无法读取遥控器语音特征。", discovery);
            return;
        }
        GattCharacteristic? transmit = null, control = null, audio = null;
        foreach (var c in atvvChars.Characteristics)
        {
            if (c.Uuid == TransmitGuid) transmit = c;
            else if (c.Uuid == ControlGuid) control = c;
            else if (c.Uuid == AudioGuid) audio = c;
        }
        bool transmitWritable = transmit.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write)
                             || transmit.CharacteristicProperties.HasFlag(GattCharacteristicProperties.WriteWithoutResponse);
        if (transmit is null || control is null || audio is null || !transmitWritable)
        {
            await FailAsync("遥控器语音特征或权限不符合 RC003-MS 协议。", discovery);
            return;
        }
        lock (_gate) { _transmit = transmit; _control = control; _audio = audio; }
        await SubscribeAsync(discovery);
    }

    /// <summary>Subscribe control first, then audio; GET_CAPS once both confirm.</summary>
    private async Task SubscribeAsync(bool discovery)
    {
        GattCharacteristic? control, audio, transmit;
        bool audioEnabled;
        lock (_gate) { control = _control; audio = _audio; transmit = _transmit; audioEnabled = _configuration!.AudioEnabled; }
        if (control is null || transmit is null)
        {
            await FailAsync("语音特征丢失；服务已停止。", discovery);
            return;
        }

        // Control CCCD
        var controlStatus = await control.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify);
        Log($"控制 CCCD 订阅：{controlStatus}");
        if (controlStatus != GattCommunicationStatus.Success)
        {
            await FailAsync("语音通知订阅失败；服务已停止。", discovery);
            return;
        }
        control.ValueChanged += OnControlChanged;
        lock (_gate) _controlSubscribed = true;

        Rc003VoiceHandshake handshake;
        lock (_gate) handshake = _handshake!;
        bool requestCaps = handshake.Confirm(Rc003VoiceHandshake.Channel.Control);
        bool capsWritten = !requestCaps || await WriteAsync(Rc003VoiceProtocol.GetCapabilities.ToArray());
        Log($"GET_CAPS 发送：request={requestCaps} written={capsWritten}，等待遥控器能力响应…");
        if (!capsWritten)
        {
            await FailAsync("无法请求遥控器语音能力。", discovery);
            return;
        }
        if (requestCaps)
        {
            // Watchdog: if the capability notification never arrives, fail
            // loudly instead of hanging until the outer discovery reset.
            int generation = Volatile.Read(ref _generation);
            _ = Task.Delay(TimeSpan.FromSeconds(6)).ContinueWith(_ =>
            {
                bool done;
                lock (_gate) done = _capsValidated || _phase is not (VoicePhase.Handshaking or VoicePhase.Connecting);
                if (!done && Volatile.Read(ref _generation) == generation)
                {
                    Log("能力响应 6 秒未到；判定本次握手失败。");
                    _ = FailAsync("遥控器未回应语音能力查询；请重试。", discovery);
                }
            }, TaskScheduler.Default);
        }

        // Audio CCCD (only when an output sink was selected)
        if (audioEnabled)
        {
            if (audio is null)
            {
                await FailAsync("语音通知订阅失败；服务已停止。", discovery);
                return;
            }
            var audioStatus = await audio.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (audioStatus != GattCommunicationStatus.Success)
            {
                await FailAsync("语音通知订阅失败；服务已停止。", discovery);
                return;
            }
            audio.ValueChanged += OnAudioChanged;
            lock (_gate) _audioSubscribed = true;
            if (handshake.Confirm(Rc003VoiceHandshake.Channel.Audio)
                && !await WriteAsync(Rc003VoiceProtocol.GetCapabilities.ToArray()))
            {
                await FailAsync("无法请求遥控器语音能力。", discovery);
                return;
            }
        }
    }

    private static string CleanIdentityText(byte[] data)
    {
        var text = System.Text.Encoding.UTF8.GetString(data);
        return new string(text.Where(ch => !char.IsWhiteSpace(ch) && !char.IsControl(ch)).ToArray());
    }

    private static byte[] DataToArray(Windows.Storage.Streams.IBuffer buffer)
    {
        CryptographicBuffer.CopyToByteArray(buffer, out byte[] array);
        return array;
    }

    private async Task<bool> WriteAsync(byte[] data)
    {
        GattCharacteristic? transmit;
        lock (_gate) transmit = _transmit;
        if (transmit is null) return false;
        var result = await transmit.WriteValueWithResultAsync(data.AsBuffer());
        return result.Status == GattCommunicationStatus.Success;
    }

    private async Task FailAsync(string message, bool discovery)
    {
        await StopAsync(message);
        if (discovery) CompleteDiscovery([], message);
    }

    private void SetPhase(VoicePhase phase) { lock (_gate) _phase = phase; }

    private static Guid PnpGuid => Guid.Parse("00002a50-0000-1000-8000-00805f9b34fb");
    private static Guid ManufacturerGuid => Guid.Parse("00002a29-0000-1000-8000-00805f9b34fb");
    private static Guid ModelGuid => Guid.Parse("00002a24-0000-1000-8000-00805f9b34fb");
    private static Guid HardwareGuid => Guid.Parse("00002a27-0000-1000-8000-00805f9b34fb");
    private static Guid FirmwareGuid => Guid.Parse("00002a26-0000-1000-8000-00805f9b34fb");
    private static Guid SoftwareGuid => Guid.Parse("00002a28-0000-1000-8000-00805f9b34fb");
}
