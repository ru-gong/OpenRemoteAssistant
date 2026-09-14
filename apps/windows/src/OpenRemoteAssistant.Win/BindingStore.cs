// SPDX-License-Identifier: GPL-3.0-only
// Persistent binding + settings under %LOCALAPPDATA%\OpenRemoteAssistant.

namespace OpenRemoteAssistant.Win;

public sealed class BindingStore
{
    public string DirectoryPath { get; }
    public string BindingFile { get; }
    public string SettingsFile { get; }
    private string _recordingsFolder = "";

    public BindingStore()
    {
        DirectoryPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenRemoteAssistant");
        BindingFile = Path.Combine(DirectoryPath, "binding.json");
        SettingsFile = Path.Combine(DirectoryPath, "settings.json");
        Directory.CreateDirectory(DirectoryPath);
        Load();
    }

    public DeviceBinding? Current { get; private set; }

    public string RecordingsFolder
    {
        get => _recordingsFolder;
        set { _recordingsFolder = value; SaveSettings(); }
    }

    public void Save(DeviceBinding binding)
    {
        Current = binding;
        File.WriteAllText(BindingFile, Serialize(binding), System.Text.Encoding.UTF8);
    }

    public void Clear()
    {
        Current = null;
        try { File.Delete(BindingFile); } catch { }
    }

    private void Load()
    {
        try
        {
            if (File.Exists(BindingFile))
            {
                var text = File.ReadAllText(BindingFile, System.Text.Encoding.UTF8);
                Current = Deserialize(text);
            }
        }
        catch { Current = null; }
        try
        {
            if (File.Exists(SettingsFile))
            {
                var text = File.ReadAllText(SettingsFile, System.Text.Encoding.UTF8);
                var start = text.IndexOf("\"recordingsFolder\":", StringComparison.Ordinal);
                if (start >= 0)
                {
                    int q1 = text.IndexOf('"', start + 19);
                    int q2 = text.IndexOf('"', q1 + 1);
                    if (q1 > 0 && q2 > q1) _recordingsFolder = Unescape(text[(q1 + 1)..q2]);
                }
            }
        }
        catch { }
        if (string.IsNullOrEmpty(_recordingsFolder))
        {
            _recordingsFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
                "RemoteAssistant");
        }
    }

    private void SaveSettings()
    {
        try
        {
            File.WriteAllText(SettingsFile,
                "{\n  \"recordingsFolder\": " + MiniJson.Quote(_recordingsFolder) + "\n}\n",
                System.Text.Encoding.UTF8);
        }
        catch { }
    }

    private static string Serialize(DeviceBinding b) =>
        "{\n"
        + "  \"profileId\": " + MiniJson.Quote(b.ProfileId) + ",\n"
        + "  \"bluetoothAddress\": " + MiniJson.Quote(b.BluetoothAddress) + ",\n"
        + "  \"identity\": {\n"
        + "    \"manufacturer\": " + MiniJson.Quote(b.Identity?.Manufacturer ?? "") + ",\n"
        + "    \"model\": " + MiniJson.Quote(b.Identity?.Model ?? "") + ",\n"
        + "    \"hardware\": " + MiniJson.Quote(b.Identity?.Hardware ?? "") + ",\n"
        + "    \"firmware\": " + MiniJson.Quote(b.Identity?.Firmware ?? "") + ",\n"
        + "    \"software\": " + MiniJson.Quote(b.Identity?.Software ?? "") + ",\n"
        + "    \"pnp\": {\n"
        + "      \"vendorIdSource\": " + (b.Identity?.Pnp?.VendorIdSource ?? 0) + ",\n"
        + "      \"vendorId\": " + (b.Identity?.Pnp?.VendorId ?? 0) + ",\n"
        + "      \"productId\": " + (b.Identity?.Pnp?.ProductId ?? 0) + ",\n"
        + "      \"productVersion\": " + (b.Identity?.Pnp?.ProductVersion ?? 0) + "\n"
        + "    }\n"
        + "  },\n"
        + "  \"confirmedAt\": " + MiniJson.Quote(b.ConfirmedAt) + ",\n"
        + "  \"singleRemoteConfirmed\": " + (b.SingleRemoteConfirmed ? "true" : "false") + "\n"
        + "}\n";

    private static DeviceBinding? Deserialize(string json)
    {
        // Minimal flat parser for our own hand-written schema.
        try
        {
            string Field(string name)
            {
                var marker = "\"" + name + "\":";
                var at = json.IndexOf(marker, StringComparison.Ordinal);
                if (at < 0) return "";
                at += marker.Length;
                while (at < json.Length && (json[at] == ' ' || json[at] == '\n' || json[at] == '\r' || json[at] == '\t')) at++;
                if (at >= json.Length) return "";
                if (json[at] == '"')
                {
                    int q2 = json.IndexOf('"', at + 1);
                    return Unescape(json[(at + 1)..q2]);
                }
                int end = at;
                while (end < json.Length && ",}\n".IndexOf(json[end]) < 0) end++;
                return json[at..end].Trim();
            }

            var identity = new RemoteDeviceIdentity(
                Field("manufacturer"), Field("model"), Field("hardware"),
                Field("firmware"), Field("software"),
                new RemoteDevicePnpIdentity(
                    (byte)int.Parse(Field("vendorIdSource")),
                    ushort.Parse(Field("vendorId")),
                    ushort.Parse(Field("productId")),
                    ushort.Parse(Field("productVersion"))));
            return new DeviceBinding
            {
                ProfileId = Field("profileId"),
                BluetoothAddress = Field("bluetoothAddress"),
                Identity = identity,
                ConfirmedAt = Field("confirmedAt"),
                SingleRemoteConfirmed = Field("singleRemoteConfirmed") == "true",
            };
        }
        catch { return null; }
    }

    private static string Unescape(string s)
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '\\' && i + 1 < s.Length)
            {
                i++;
                sb.Append(s[i] switch
                {
                    'n' => '\n', 'r' => '\r', 't' => '\t', '"' => '"', '\\' => '\\',
                    _ => s[i],
                });
            }
            else sb.Append(s[i]);
        }
        return sb.ToString();
    }
}
