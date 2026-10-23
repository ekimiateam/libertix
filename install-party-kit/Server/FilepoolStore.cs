using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.Models;

namespace Libertix.InstallParty;

public sealed class FilepoolStore : IDisposable
{
    private const int DownloadBufferBytes = 1024 * 1024;
    private const int MaximumCatalogBytes = 1024 * 1024;
    private const int MaximumSignatureBytes = 16 * 1024;
    private const int MaximumStoredCatalogBytes = 2 * MaximumCatalogBytes;
    private static readonly TimeSpan MetadataTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DownloadIdleTimeout = TimeSpan.FromMinutes(2);
    private readonly KitSettings settings;
    private readonly ILogger logger;
    private readonly string root;
    private readonly FileStream ownership;
    private readonly HttpClient http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private readonly SemaphoreSlim update = new(1, 1);
    private readonly object gate = new();
    private Dictionary<string, CatalogArtifactJson> available = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, object> transfers = new();
    private readonly Dictionary<string, int> readers = new(StringComparer.Ordinal);
    private readonly HashSet<string> obsolete = new(StringComparer.Ordinal);
    private string phase = "Waiting for initial verification";
    private string fileName = "";
    private long received;
    private long total;
    private string lastError;
    private bool updating;

    public FilepoolStore(KitSettings settings, ILogger logger)
    {
        this.settings = settings;
        this.logger = logger;
        root = Path.Combine(settings.StorageDirectory, "libertix-managed");
        Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Managed storage must not be a symbolic link.");
        ownership = new FileStream(Path.Combine(root, ".lock"), FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);
        ReadPreviousArtifactIdentities();
    }

    private void ReadPreviousArtifactIdentities()
    {
        string previousCatalog = Path.Combine(root, "catalog-snapshot.json");
        if (File.Exists(previousCatalog))
        {
            if (new FileInfo(previousCatalog).Length > MaximumStoredCatalogBytes)
                throw new InvalidDataException("The stored catalog exceeds the metadata limit.");
            var snapshot = JsonSerializer.Deserialize<CatalogSnapshot>(File.ReadAllText(previousCatalog));
            byte[] manifest = Convert.FromBase64String(snapshot.Manifest);
            DistributionCatalogTrust.VerifyWithApplicationKey(manifest, snapshot.Signature);
            foreach (var file in CatalogFiles.GetAll(JsonSerializer.Deserialize<DistributionCatalogJson>(manifest)))
                obsolete.Add(Identity(file));
        }
    }

    public bool Ready { get { lock (gate) return available.Count > 0; } }

    public object Status()
    {
        lock (gate)
            return new { ready = available.Count > 0, updating, phase, fileName, received, total,
                lastError, files = available.Count, transfers = transfers.Values.ToArray() };
    }

    public async Task<bool> UpdateAsync(CancellationToken cancellationToken)
    {
        if (!await update.WaitAsync(0, cancellationToken))
            return false;
        lock (gate) { updating = true; lastError = null; phase = "Verifying official catalog"; }
        try
        {
            var catalog = await ReadOfficialCatalogAsync(cancellationToken);
            var next = await PrepareArtifactsAsync(catalog.Source, catalog.Files, cancellationToken);
            PublishCatalog(catalog.Manifest, catalog.Signature, next);
            logger.LogInformation("Verified {Count} artifacts for {Channel}", catalog.Files.Count, settings.Channel);
            return true;
        }
        catch (Exception error) when (error is HttpRequestException || error is IOException ||
            error is JsonException || error is CryptographicException || error is ArgumentException ||
            error is OperationCanceledException)
        {
            lock (gate) { lastError = error.Message; phase = "Update failed; previous verified files retained"; }
            logger.LogError(error, "Filepool update failed");
            return false;
        }
        finally
        {
            lock (gate) updating = false;
            update.Release();
        }
    }

    private async Task<(FilepoolConfig Source, byte[] Manifest, byte[] Signature,
        IReadOnlyList<CatalogArtifactJson> Files)> ReadOfficialCatalogAsync(CancellationToken token)
    {
        var source = FilepoolConfig.ForBuild(ApplicationBuild.Parse(
            settings.Channel == "dev" ? "dev_0000000" : "0.0"));
        byte[] manifest = await ReadMetadataAsync(source.CatalogUrl, MaximumCatalogBytes, token);
        byte[] signature = await ReadMetadataAsync(source.CatalogSignatureUrl, MaximumSignatureBytes, token);
        DistributionCatalogTrust.VerifyWithApplicationKey(manifest, Encoding.UTF8.GetString(signature));
        var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(manifest);
        return (source, manifest, signature, CatalogFiles.GetAll(catalog));
    }

    private async Task<Dictionary<string, CatalogArtifactJson>> PrepareArtifactsAsync(
        FilepoolConfig source, IReadOnlyList<CatalogArtifactJson> files, CancellationToken token)
    {
        var next = new Dictionary<string, CatalogArtifactJson>(StringComparer.Ordinal);
        foreach (var file in files)
        {
            string identity = Identity(file);
            string path = Path.Combine(root, identity);
            Report("Verifying cached file", file, 0);
            if (!await VerifyAsync(path, file, token))
                await ReplaceArtifactAsync(source, file, identity, path, token);
            next.Add(identity, file);
        }
        return next;
    }

    private async Task ReplaceArtifactAsync(FilepoolConfig source, CatalogArtifactJson file,
        string identity, string path, CancellationToken token)
    {
        // Published files are immutable while readers hold them, even if an
        // operator has changed one on disk since the previous verification.
        lock (gate)
            if (readers.ContainsKey(identity))
                throw new IOException("A modified artifact is still being served; retry after transfers finish.");
        await DownloadAsync(source.ResolveUrl(file.Url), path + ".partial", file, token);
        if (!await VerifyAsync(path + ".partial", file, token))
            throw new InvalidDataException("Downloaded artifact failed size/SHA-256 verification: " + file.FileName);
        lock (gate)
        {
            if (readers.ContainsKey(identity))
                throw new IOException("An artifact is still being served; retry after transfers finish.");
            File.Move(path + ".partial", path, true);
        }
    }

    private void PublishCatalog(byte[] manifest, byte[] signature, Dictionary<string, CatalogArtifactJson> next)
    {
        string snapshotPath = Path.Combine(root, "catalog-snapshot.json");
        File.WriteAllText(snapshotPath + ".new", JsonSerializer.Serialize(new CatalogSnapshot(
            Convert.ToBase64String(manifest), Encoding.UTF8.GetString(signature))));
        File.Move(snapshotPath + ".new", snapshotPath, true);
        lock (gate)
        {
            foreach (string previous in available.Keys.Except(next.Keys))
                obsolete.Add(previous);
            available = next;
            obsolete.ExceptWith(next.Keys);
            phase = "Ready";
            fileName = "";
            received = total = 0;
            RemoveUnusedFiles();
        }
    }

    private async Task<byte[]> ReadMetadataAsync(string url, long limit, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(MetadataTimeout);
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        return await BoundedHttpContent.ReadAsync(response.Content, limit, timeout.Token);
    }

    private async Task DownloadAsync(string url, string path, CatalogArtifactJson file, CancellationToken token)
    {
        EnsureRegularFile(path);
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(token);
        idle.CancelAfter(DownloadIdleTimeout);
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, idle.Token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength.HasValue &&
            response.Content.Headers.ContentLength.Value != file.SizeBytes)
            throw new InvalidDataException("Downloaded size differs from the signed catalog: " + file.FileName);
        await using var input = await response.Content.ReadAsStreamAsync(idle.Token);
        await using var output = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None,
            DownloadBufferBytes, FileOptions.Asynchronous);
        var buffer = new byte[DownloadBufferBytes];
        long count = 0;
        int read;
        while ((read = await input.ReadAsync(buffer, idle.Token)) != 0)
        {
            if (count > file.SizeBytes - read)
                throw new InvalidDataException("Download exceeded the signed size: " + file.FileName);
            await output.WriteAsync(buffer.AsMemory(0, read), idle.Token);
            count += read;
            Report("Downloading", file, count);
            idle.CancelAfter(DownloadIdleTimeout);
        }
    }

    private void Report(string state, CatalogArtifactJson file, long count)
    {
        lock (gate) { phase = state; fileName = file.FileName; received = count; total = file.SizeBytes; }
    }

    private static void EnsureRegularFile(string path)
    {
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Filepool artifacts must not be symbolic links.");
    }

    private static async Task<bool> VerifyAsync(string path, CatalogArtifactJson file, CancellationToken token)
    {
        EnsureRegularFile(path);
        if (!File.Exists(path) || new FileInfo(path).Length != file.SizeBytes)
            return false;
        await using var stream = File.OpenRead(path);
        byte[] hash = await SHA256.HashDataAsync(stream, token);
        return Convert.ToHexString(hash).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    private static string Identity(CatalogArtifactJson file) =>
        file.Sha256.ToLowerInvariant() + "-" + file.FileName;

    public async Task ServeAsync(HttpContext context, string hash, string name)
    {
        try { FilepoolProtocol.ArtifactPath(name, hash); }
        catch (ArgumentException) { context.Response.StatusCode = StatusCodes.Status404NotFound; return; }
        string identity = hash.ToLowerInvariant() + "-" + name;
        Guid transfer = Guid.NewGuid();
        FileStream stream = OpenTransfer(context, identity, name, transfer);
        if (stream == null)
            return;
        try
        {
            context.Response.Headers.CacheControl = "no-store";
            await Results.File(stream, "application/octet-stream", enableRangeProcessing: true)
                .ExecuteAsync(context);
        }
        finally
        {
            await stream.DisposeAsync();
            lock (gate)
            {
                transfers.Remove(transfer);
                if (--readers[identity] == 0) readers.Remove(identity);
                RemoveUnusedFiles();
            }
        }
    }

    private FileStream OpenTransfer(HttpContext context, string identity, string name, Guid transfer)
    {
        lock (gate)
        {
            if (!available.TryGetValue(identity, out var file))
            {
                context.Response.StatusCode = StatusCodes.Status404NotFound;
                return null;
            }
            string path = Path.Combine(root, identity);
            EnsureRegularFile(path);
            var stream = File.OpenRead(path);
            if (stream.Length != file.SizeBytes)
            {
                stream.Dispose();
                context.Response.StatusCode = StatusCodes.Status409Conflict;
                return null;
            }
            readers.TryGetValue(identity, out int count);
            readers[identity] = count + 1;
            transfers.Add(transfer, new { client = context.Connection.RemoteIpAddress?.ToString(),
                file = name, started = DateTimeOffset.UtcNow });
            return stream;
        }
    }

    private void RemoveUnusedFiles()
    {
        foreach (string identity in obsolete.Where(item => !readers.ContainsKey(item)).ToArray())
        {
            try
            {
                File.Delete(Path.Combine(root, identity));
                obsolete.Remove(identity);
            }
            catch (IOException error) { logger.LogWarning("Unused artifact retained: {Reason}", error.Message); }
            catch (UnauthorizedAccessException error) { logger.LogWarning("Unused artifact retained: {Reason}", error.Message); }
        }
    }

    public void Dispose()
    {
        http.Dispose();
        ownership.Dispose();
        update.Dispose();
    }

    private sealed record CatalogSnapshot(string Manifest, string Signature);
}
