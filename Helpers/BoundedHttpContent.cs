using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Libertix.Helpers
{
    internal static class BoundedHttpContent
    {
        public static async Task<byte[]> ReadAsync(
            HttpContent content,
            long maximumBytes,
            CancellationToken cancellationToken)
        {
            if (content == null)
                throw new ArgumentNullException(nameof(content));
            if (maximumBytes <= 0)
                throw new ArgumentOutOfRangeException(nameof(maximumBytes));
            if (content.Headers.ContentLength > maximumBytes)
                throw new InvalidDataException($"HTTP content exceeds {maximumBytes} bytes.");

            using (Stream source = await content.ReadAsStreamAsync())
            using (var destination = new MemoryStream())
            {
                var buffer = new byte[8192];
                long total = 0;
                int read;
                while ((read = await source.ReadAsync(
                    buffer,
                    0,
                    buffer.Length,
                    cancellationToken)) > 0)
                {
                    if (total > maximumBytes - read)
                        throw new InvalidDataException(
                            $"HTTP content exceeds {maximumBytes} bytes.");
                    destination.Write(buffer, 0, read);
                    total += read;
                }
                return destination.ToArray();
            }
        }
    }
}
