using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Libertix.InstallParty;

public sealed class ServerCertificate : IDisposable
{
    private const int RsaKeyBits = 3072;
    private const int ValidityYears = 1;
    private const int RenewalLeadDays = 30;
    private const int ClockSkewMinutes = 5;
    private static readonly TimeSpan InspectionInterval = TimeSpan.FromMinutes(1);
    private readonly string path;
    private readonly ILogger logger;
    private readonly List<X509Certificate2> retired = new();
    private readonly object gate = new();
    private X509Certificate2 current;
    private DateTime nextCheck;

    public ServerCertificate(string stateDirectory, ILogger logger)
    {
        path = Path.Combine(stateDirectory, "server.pfx");
        this.logger = logger;
        Select();
    }

    public static IPAddress[] Addresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(network => network.OperationalStatus == OperationalStatus.Up)
        .SelectMany(network => network.GetIPProperties().UnicastAddresses)
        .Select(item => item.Address)
        .Select(address => new IPAddress(address.GetAddressBytes()))
        .Append(IPAddress.Loopback).Append(IPAddress.IPv6Loopback)
        .Distinct().OrderBy(address => address.ToString(), StringComparer.Ordinal).ToArray();

    public X509Certificate2 Select()
    {
        lock (gate)
        {
            if (current != null && DateTime.UtcNow < nextCheck)
                return current;
            var addresses = Addresses();
            LoadCachedCertificate();
            if (!IsValid(current, addresses))
                RenewCertificate(addresses);
            nextCheck = DateTime.UtcNow.Add(InspectionInterval);
            return current;
        }
    }

    private void LoadCachedCertificate()
    {
        if (current != null || !File.Exists(path))
            return;
        try
        {
            current = X509CertificateLoader.LoadPkcs12FromFile(path, null);
        }
        catch (CryptographicException error)
        {
            logger.LogWarning("Replacing invalid server certificate: {Reason}", error.Message);
        }
    }

    private void RenewCertificate(IPAddress[] addresses)
    {
        using var key = RSA.Create(RsaKeyBits);
        var request = new CertificateRequest("CN=Libertix Install Party", key,
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var names = new SubjectAlternativeNameBuilder();
        foreach (var address in addresses)
            names.AddIpAddress(address);
        request.CertificateExtensions.Add(names.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));
        using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-ClockSkewMinutes),
            DateTimeOffset.UtcNow.AddYears(ValidityYears));
        byte[] pfx = created.Export(X509ContentType.Pfx);
        File.WriteAllBytes(path + ".tmp", pfx);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(path + ".tmp", UnixFileMode.UserRead | UnixFileMode.UserWrite);
        File.Move(path + ".tmp", path, true);
        if (current != null)
            retired.Add(current);
        current = X509CertificateLoader.LoadPkcs12(pfx, null);
        logger.LogInformation("HTTPS certificate generated for {Addresses}",
            string.Join(", ", addresses.Select(address => address.ToString())));
    }

    private static bool IsValid(X509Certificate2 certificate, IPAddress[] addresses)
    {
        if (certificate == null || !certificate.HasPrivateKey ||
            certificate.NotBefore.ToUniversalTime() > DateTime.UtcNow ||
            certificate.NotAfter.ToUniversalTime() < DateTime.UtcNow.AddDays(RenewalLeadDays))
            return false;
        var names = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().SingleOrDefault();
        return names != null && names.EnumerateIPAddresses().ToHashSet().SetEquals(addresses);
    }

    public void Dispose()
    {
        current?.Dispose();
        foreach (var certificate in retired)
            certificate.Dispose();
    }
}
