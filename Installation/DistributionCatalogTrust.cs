using System;
using System.IO;
using System.Security.Cryptography;

namespace Libertix.Installation
{
    /// <summary>
    /// Verifies that production artifact URLs and hashes were authorized by the
    /// offline catalogue signing key bundled with the application.
    /// </summary>
    public static class DistributionCatalogTrust
    {
        private const string ApplicationPublicKeyResource =
            "Libertix.Resources.CatalogPublicKey.xml";

        public static void Verify(byte[] manifest, string signatureBase64, string publicKeyPath)
        {
            if (manifest == null || manifest.Length == 0)
                throw new InvalidDataException("Distribution manifest is empty.");
            if (string.IsNullOrWhiteSpace(signatureBase64))
                throw new InvalidDataException("Distribution manifest signature is missing.");
            if (string.IsNullOrWhiteSpace(publicKeyPath) || !File.Exists(publicKeyPath))
                throw new FileNotFoundException(
                    "Distribution catalogue public key is missing.",
                    publicKeyPath);

            VerifyWithPublicKeyXml(
                manifest,
                signatureBase64,
                File.ReadAllText(publicKeyPath));
        }

        public static void VerifyWithApplicationKey(byte[] manifest, string signatureBase64)
        {
            using (Stream keyStream = typeof(DistributionCatalogTrust).Assembly
                .GetManifestResourceStream(ApplicationPublicKeyResource))
            {
                if (keyStream == null)
                    throw new InvalidDataException(
                        "The embedded distribution catalogue public key is missing.");
                using (var reader = new StreamReader(keyStream))
                    VerifyWithPublicKeyXml(manifest, signatureBase64, reader.ReadToEnd());
            }
        }

        private static void VerifyWithPublicKeyXml(
            byte[] manifest,
            string signatureBase64,
            string publicKeyXml)
        {
            if (manifest == null || manifest.Length == 0)
                throw new InvalidDataException("Distribution manifest is empty.");
            if (string.IsNullOrWhiteSpace(signatureBase64))
                throw new InvalidDataException("Distribution manifest signature is missing.");

            byte[] signature;
            try
            {
                signature = Convert.FromBase64String(signatureBase64.Trim());
            }
            catch (FormatException exception)
            {
                throw new InvalidDataException(
                    "Distribution manifest signature is not valid Base64.",
                    exception);
            }

            using (var rsa = new RSACryptoServiceProvider())
            {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(publicKeyXml);
                if (!rsa.VerifyData(
                    manifest,
                    CryptoConfig.MapNameToOID("SHA256"),
                    signature))
                {
                    throw new InvalidDataException(
                        "Distribution manifest signature verification failed.");
                }
            }
        }
    }
}
