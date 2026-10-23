using System;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;

namespace Libertix.Helpers
{
    // Shared by WPF and Windows PowerShell. Plain HTTP is enough: every artifact is
    // verified against the signed official catalog before use.
    public static class LocalFilepoolDownload
    {
        private const int BufferSize = 81920;
        private static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(120);

        public static async Task DownloadAsync(
            string acceptedServer, string url, string destination, long maximumBytes,
            Action<long, long> progress, CancellationToken cancellationToken)
        {
            Uri target = ValidateDownloadTarget(acceptedServer, url, maximumBytes);
            var request = CreateScopedRequest(target);
            using (var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            using (idle.Token.Register(request.Abort))
            {
                idle.CancelAfter(IdleTimeout);
                using (var response = (HttpWebResponse)await request.GetResponseAsync().ConfigureAwait(false))
                    await SaveResponseAsync(response, destination, maximumBytes, progress, idle).ConfigureAwait(false);
            }
        }

        private static Uri ValidateDownloadTarget(string acceptedServer, string url, long maximumBytes)
        {
            var server = new Uri(acceptedServer);
            var target = new Uri(url);
            IPAddress address;
            if (server.Scheme != Uri.UriSchemeHttp ||
                !IPAddress.TryParse(server.Host.Trim('[', ']'), out address) ||
                target.Scheme != server.Scheme || target.Host != server.Host ||
                target.Port != server.Port || target.UserInfo.Length != 0 ||
                target.Fragment.Length != 0 || target.Query.Length != 0 ||
                !target.AbsolutePath.StartsWith("/files/", StringComparison.Ordinal) ||
                maximumBytes <= 0)
                throw new InvalidOperationException("Download outside the accepted local filepool refused.");
            return target;
        }

        private static HttpWebRequest CreateScopedRequest(Uri target)
        {
            var request = (HttpWebRequest)WebRequest.Create(target);
            request.AllowAutoRedirect = false;
            request.Proxy = null;
            return request;
        }

        private static async Task SaveResponseAsync(HttpWebResponse response, string destination,
            long maximumBytes, Action<long, long> progress, CancellationTokenSource idle)
        {
            if (response.StatusCode != HttpStatusCode.OK)
                throw new IOException("Local filepool redirects and non-OK responses are refused.");
            long size = response.ContentLength;
            if (size <= 0 || size > maximumBytes)
                throw new IOException("Local filepool returned an invalid artifact size.");
            using (var input = response.GetResponseStream())
            using (var output = new FileStream(destination, FileMode.Create,
                FileAccess.Write, FileShare.None, BufferSize, true))
            {
                var buffer = new byte[BufferSize];
                long total = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, 0, buffer.Length, idle.Token)
                    .ConfigureAwait(false)) != 0)
                {
                    if (total > size - read)
                        throw new IOException("Local filepool exceeded the declared artifact size.");
                    await output.WriteAsync(buffer, 0, read, idle.Token).ConfigureAwait(false);
                    total += read;
                    if (progress != null)
                        progress(total, size);
                    idle.CancelAfter(IdleTimeout);
                }
                if (total != size)
                    throw new IOException("Local filepool transfer is incomplete.");
            }
        }
    }
}
