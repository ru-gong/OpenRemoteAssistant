// SPDX-License-Identifier: GPL-3.0-only
// Device finder: enumerate RC003-MS candidates known to the system
// (equivalent of CBCentralManager retrieveConnectedPeripherals(withServices:)).

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Enumeration;

namespace OpenRemoteAssistant.Win;

public sealed record FoundRemote(ulong Address, string Name);

public static class RemoteFinder
{
    private static readonly Guid ServiceGuid = new(Rc003VoiceProtocol.ServiceUuid);

    /// <summary>
    /// Devices that expose the ATVV GATT service. Enumerates system-paired
    /// Bluetooth LE devices and verifies the ATVV service against the system
    /// GATT cache first (fast, no over-the-air discovery), falling back to an
    /// uncached probe only when the cache yields nothing.
    /// Mirrors the upstream rule: only the exact ATVV service is eligible —
    /// no name-based identity, no unrelated HID fallback.
    /// </summary>
    public static async Task<List<FoundRemote>> FindConnectedRemotesAsync(CancellationToken cancellation)
    {
        var found = await VerifyPairedDevicesAsync(BluetoothCacheMode.Cached, cancellation);
        if (found.Count == 0)
            found = await VerifyPairedDevicesAsync(BluetoothCacheMode.Uncached, cancellation);
        return found;
    }

    /// <summary>Fast path: is the given address alive and still exposing ATVV?</summary>
    public static async Task<FoundRemote?> ProbeBoundAsync(ulong address, string name, CancellationToken cancellation)
    {
        try
        {
            using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (device is null) return null;
            var services = await device.GetGattServicesForUuidAsync(ServiceGuid, BluetoothCacheMode.Cached);
            if (services.Status == GattCommunicationStatus.Success && services.Services.Count > 0)
                return new FoundRemote(address, name);
        }
        catch { }
        return null;
    }

    private static async Task<List<FoundRemote>> VerifyPairedDevicesAsync(BluetoothCacheMode mode, CancellationToken cancellation)
    {
        var found = new Dictionary<ulong, FoundRemote>();
        var paired = await DeviceInformation.FindAllAsync(
            BluetoothLEDevice.GetDeviceSelectorFromPairingState(true),
            new[] { "System.ItemNameDisplay" });
        foreach (var info in paired)
        {
            if (cancellation.IsCancellationRequested) break;
            if (!TryParseAddressFromId(info.Id, out var address)) continue;
            if (found.ContainsKey(address)) continue;
            try
            {
                using var device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
                if (device is null) continue;
                var services = await device.GetGattServicesForUuidAsync(ServiceGuid, mode);
                if (services.Status == GattCommunicationStatus.Success && services.Services.Count > 0)
                    found[address] = new FoundRemote(address, string.IsNullOrEmpty(info.Name) ? device.Name : info.Name);
            }
            catch
            {
                // Unreachable or busy device: not a candidate.
            }
        }
        return [.. found.Values];
    }

    /// <summary>
    /// BluetoothLE device ids look like
    /// "BluetoothLE#BluetoothLE{local-mac-with-colons}-{device-mac-with-colons}".
    /// The device address is the segment after the last '-'.
    /// </summary>
    private static bool TryParseAddressFromId(string id, out ulong address)
    {
        address = 0;
        var marker = "BluetoothLE#BluetoothLE";
        var at = id.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (at < 0) return false;
        var rest = id[(at + marker.Length)..];
        var dash = rest.LastIndexOf('-');
        if (dash >= 0) rest = rest[(dash + 1)..];
        var hex = new string(rest.Where(char.IsAsciiHexDigit).ToArray());
        if (hex.Length != 12) return false;
        return ulong.TryParse(hex, System.Globalization.NumberStyles.HexNumber,
            System.Globalization.CultureInfo.InvariantCulture, out address);
    }
}
