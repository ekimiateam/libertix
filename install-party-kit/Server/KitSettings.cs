using System.Text.Json;
using Libertix.Helpers;

namespace Libertix.InstallParty;

public sealed record KitSettings(string Channel, int HttpPort, string StorageDirectory)
{
    private static readonly object SaveGate = new();
    private const int MinimumHttpPort = 1024;
    private const int MaximumHttpPort = 65535;

    public static KitSettings Load(string stateDirectory)
    {
        string path = Path.Combine(stateDirectory, "settings.json");
        var settings = File.Exists(path)
            ? JsonSerializer.Deserialize<KitSettings>(File.ReadAllText(path))
            : new KitSettings("main", FilepoolProtocol.DefaultHttpPort,
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
        if (HttpPort < MinimumHttpPort || HttpPort > MaximumHttpPort || HttpPort == FilepoolProtocol.DiscoveryPort)
            throw new ArgumentException($"Choose an HTTP port between {MinimumHttpPort} and {MaximumHttpPort}, distinct from discovery.");
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
