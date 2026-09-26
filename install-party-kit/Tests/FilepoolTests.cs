using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Libertix.Helpers;
using Libertix.Installation;
using Libertix.InstallParty;
using Libertix.Models;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.InstallParty.Tests;

[TestClass]
public sealed class FilepoolTests
{
    private string root;

    [TestInitialize]
    public void Initialize()
    {
        root = Path.Combine(AppContext.BaseDirectory, "test-data", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
    }

    [TestCleanup]
    public void Cleanup() => Directory.Delete(root, true);

    [TestMethod]
    public void ServerSelectionKeepsOfficialTrustAndMapsBothRelativeAndAbsoluteArtifacts()
    {
        var original = FilepoolConfig.ForBuild(ApplicationBuild.Parse("0.3"));
        var local = original.WithLocalServer("https://127.0.0.1:18080");
        Assert.AreEqual(original.CatalogUrl, local.CatalogUrl);
        Assert.AreEqual(original.ReleasesSignatureUrl, local.ReleasesSignatureUrl);
        Assert.IsTrue(local.RequiresCatalogSignature);
        Assert.IsFalse(local.IsDevelopmentMode);
        string hash = new('a', 64);
        string expected = "https://127.0.0.1:18080/files/" + hash + "/mint.iso";
        Assert.AreEqual(expected, local.ResolveArtifactUrl("https://example.com/upstream.iso", "mint.iso", hash));
        Assert.AreEqual(expected, local.ResolveArtifactUrl("mint.iso", "mint.iso", hash));
        Assert.ThrowsException<InvalidOperationException>(() =>
            original.WithLocalDirectory(root, false).WithLocalServer("https://127.0.0.1:18080"));
    }

    [DataTestMethod]
    [DataRow("http://127.0.0.1:18080")]
    [DataRow("https://example.com")]
    [DataRow("https://127.0.0.1/path")]
    [DataRow("https://user@127.0.0.1")]
    [DataRow("https://127.0.0.1?query")]
    public void RejectsAmbiguousServerEndpoints(string endpoint) =>
        Assert.ThrowsException<ArgumentException>(() => FilepoolProtocol.ValidateServer(endpoint));

    [TestMethod]
    public void SignedCatalogIncludesDistributionIsosAndRejectsTampering()
    {
        byte[] manifest = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog.json"));
        string signature = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "catalog.json.sig"));
        DistributionCatalogTrust.VerifyWithApplicationKey(manifest, signature);
        var catalog = JsonSerializer.Deserialize<DistributionCatalogJson>(manifest);
        var files = CatalogFiles.GetAll(catalog);
        Assert.AreEqual(9, files.Count);
        Assert.IsTrue(files.Any(file => file.FileName == "mint.iso" && file.Url == catalog.Distributions[0].IsoInstaller));
        Assert.IsTrue(files.Any(file => file.FileName == "zorin.iso"));
        manifest[0] ^= 1;
        Assert.ThrowsException<InvalidDataException>(() =>
            DistributionCatalogTrust.VerifyWithApplicationKey(manifest, signature));
        catalog.Distributions[0].IsoInstallerFileName = "../outside.iso";
        Assert.ThrowsException<ArgumentException>(() => CatalogFiles.GetAll(catalog));
    }

    [TestMethod]
    public void SettingsDefaultToMainAndRejectInvalidPorts()
    {
        var defaults = KitSettings.Load(root);
        Assert.AreEqual("main", defaults.Channel);
        var changed = defaults with { Channel = "dev", HttpsPort = 19080 };
        changed.Save(root);
        Assert.AreEqual(changed, KitSettings.Load(root));
        Assert.ThrowsException<ArgumentException>(() => (changed with { HttpsPort = 18081 }).Validate());
        Assert.ThrowsException<ArgumentException>(() => (changed with { Channel = "other" }).Validate());
    }

    [TestMethod]
    public void CertificateContainsCurrentIpsAndReplacesAnExpiringCertificate()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=old", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var expiring = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        File.WriteAllBytes(Path.Combine(root, "server.pfx"), expiring.Export(X509ContentType.Pfx));
        string thumbprint;
        using (var manager = new ServerCertificate(root, NullLogger.Instance))
        {
            var certificate = manager.Select();
            thumbprint = certificate.Thumbprint;
            Assert.AreNotEqual(expiring.Thumbprint, thumbprint);
            Assert.IsTrue(certificate.HasPrivateKey);
            var names = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
            Assert.IsTrue(names.EnumerateIPAddresses().ToHashSet().SetEquals(ServerCertificate.Addresses()));
        }
        using var reloaded = new ServerCertificate(root, NullLogger.Instance);
        Assert.AreEqual(thumbprint, reloaded.Select().Thumbprint);
    }

    [DataTestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public async Task ScopedTlsDownloadAcceptsSelfSignedButNeverFollowsRedirects(bool redirect)
    {
        using var certificates = new ServerCertificate(root, NullLogger.Instance);
        using var server = new TcpListener(IPAddress.Loopback, 0);
        using var forbidden = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        forbidden.Start();
        int port = ((IPEndPoint)server.LocalEndpoint).Port;
        int forbiddenPort = ((IPEndPoint)forbidden.LocalEndpoint).Port;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        Task response = Task.Run(async () =>
        {
            using var peer = await server.AcceptTcpClientAsync(timeout.Token);
            using var tls = new SslStream(peer.GetStream());
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            { ServerCertificate = certificates.Select() }, timeout.Token);
            using var reader = new StreamReader(tls, Encoding.ASCII, false, 1024, true);
            while (!string.IsNullOrEmpty(await reader.ReadLineAsync(timeout.Token))) { }
            string message = redirect
                ? $"HTTP/1.1 302 Found\r\nLocation: https://127.0.0.1:{forbiddenPort}/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest";
            await tls.WriteAsync(Encoding.ASCII.GetBytes(message), timeout.Token);
        });
        string endpoint = "https://127.0.0.1:" + port;
        string destination = Path.Combine(root, "download");
        Task download = LocalFilepoolDownload.DownloadAsync(endpoint,
            endpoint + "/files/" + new string('a', 64) + "/test.iso", destination, 4, null, timeout.Token);
        if (redirect)
        {
            await Assert.ThrowsExceptionAsync<IOException>(() => download);
            Assert.IsFalse(File.Exists(destination));
        }
        else
        {
            await download;
            Assert.AreEqual("test", File.ReadAllText(destination));
        }
        await response;
        Assert.IsFalse(forbidden.Pending(), "A redirect must not cause an outbound connection.");
        await Assert.ThrowsExceptionAsync<InvalidOperationException>(() =>
            LocalFilepoolDownload.DownloadAsync(endpoint, "https://127.0.0.1:" + forbiddenPort + "/files/test",
                destination, 4, null, timeout.Token));
        Assert.IsFalse(forbidden.Pending(), "A different port must be rejected before connecting.");
    }

    [TestMethod]
    public async Task DiscoveryFiltersChannelsAndPreservesMultipleChoices()
    {
        using var server = new UdpClient(new IPEndPoint(IPAddress.Any, FilepoolProtocol.DiscoveryPort));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        Task reply = Task.Run(async () =>
        {
            var query = await server.ReceiveAsync(timeout.Token);
            string request = Encoding.ASCII.GetString(query.Buffer);
            foreach (string answer in new[]
            {
                request.Replace("|main", "|dev") + "|18080",
                request + "|18080", request + "|18082"
            })
                await server.SendAsync(Encoding.ASCII.GetBytes(answer), query.RemoteEndPoint, timeout.Token);
        });
        var found = await LocalFilepoolDiscovery.FindAsync("main");
        await reply;
        Assert.AreEqual(2, found.Count);
        Assert.IsTrue(found.Any(endpoint => endpoint.EndsWith(":18080")));
        Assert.IsTrue(found.Any(endpoint => endpoint.EndsWith(":18082")));
    }
}
