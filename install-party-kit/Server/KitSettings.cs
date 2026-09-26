using System.Text.Json;
using Libertix.Helpers;

namespace Libertix.InstallParty;

public sealed record KitSettings(string Channel, int HttpsPort, string StorageDirectory)
{
    private static readonly object SaveGate = new();
    private const int MinimumHttpsPort = 1024;
    private const int MaximumHttpsPort = 65535;

    public static KitSettings Load(string stateDirectory)
    {
        string path = Path.Combine(stateDirectory, "settings.json");
        var settings = File.Exists(path)
            ? JsonSerializer.Deserialize<KitSettings>(File.ReadAllText(path))
            : new KitSettings("main", FilepoolProtocol.DefaultHttpsPort,
                Path.Combine(stateDirectory, "storage"));
        if (settings == null)
            throw new InvalidDataException("The server settings are empty.");
        settings.Validate();
        return settings;
    }

    public void Validate()
    {
        if (Channel != "main" && Channel != "dev")
            throw new ArgumentException("Channel must be main or dev.");
        if (HttpsPort < MinimumHttpsPort || HttpsPort > MaximumHttpsPort || HttpsPort == FilepoolProtocol.DiscoveryPort)
            throw new ArgumentException($"Choose an HTTPS port between {MinimumHttpsPort} and {MaximumHttpsPort}, distinct from discovery.");
        if (string.IsNullOrWhiteSpace(StorageDirectory) || !Path.IsPathFullyQualified(StorageDirectory))
            throw new ArgumentException("The storage directory must be an absolute path.");
    }

    public void Save(string stateDirectory)
    {
        Validate();
        string path = Path.Combine(stateDirectory, "settings.json");
        lock (SaveGate)
        {
            File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(this, new JsonSerializerOptions
            { WriteIndented = true }));
            File.Move(path + ".tmp", path, true);
        }
    }
}
