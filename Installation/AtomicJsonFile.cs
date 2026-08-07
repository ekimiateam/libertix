using System;
using System.IO;
using System.Text;
using System.Threading;

namespace Libertix.Installation
{
    /// <summary>
    /// Publishes UTF-8 JSON with a same-directory atomic rename. Readers either
    /// see the previous complete document or the new complete document.
    /// </summary>
    internal static class AtomicJsonFile
    {
        private const int MaxPublishAttempts = 8;
        private static readonly Encoding Utf8WithoutBom = new UTF8Encoding(false);

        public static void Write(string path, string json)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A JSON file path is required.", nameof(path));
            if (json == null)
                throw new ArgumentNullException(nameof(json));

            string fullPath = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(fullPath);
            if (string.IsNullOrEmpty(directory))
                throw new InvalidOperationException("The JSON file path has no parent directory.");

            Directory.CreateDirectory(directory);
            string temporaryPath = Path.Combine(
                directory,
                $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");

            try
            {
                using (var stream = new FileStream(
                    temporaryPath,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    4096,
                    FileOptions.WriteThrough))
                using (var writer = new StreamWriter(stream, Utf8WithoutBom))
                {
                    writer.Write(json);
                    writer.Write('\n');
                    writer.Flush();
                    stream.Flush(true);
                }

                Publish(temporaryPath, fullPath);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }

        private static void Publish(string temporaryPath, string fullPath)
        {
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    if (File.Exists(fullPath))
                        File.Replace(temporaryPath, fullPath, null);
                    else
                        File.Move(temporaryPath, fullPath);
                    return;
                }
                catch (Exception exception)
                    when (attempt < MaxPublishAttempts && IsTransientPublishFailure(exception))
                {
                    // Indexers and antivirus scanners can briefly deny the replace even
                    // after both application streams are closed. Retrying the same
                    // same-directory rename preserves the atomic publication contract.
                    Thread.Sleep(25 * attempt);
                }
            }
        }

        private static bool IsTransientPublishFailure(Exception exception)
        {
            if (!(exception is IOException) && !(exception is UnauthorizedAccessException))
                return false;

            int win32Code = exception.HResult & 0xFFFF;
            return win32Code == 5
                || win32Code == 32
                || win32Code == 33
                || win32Code == 1175
                || win32Code == 1176
                || win32Code == 1177;
        }
    }
}
