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
        private const int ErrorAccessDenied = 5;
        private const int ErrorSharingViolation = 32;
        private const int ErrorLockViolation = 33;
        private const int ErrorUnableToRemoveReplaced = 1175;
        private const int ErrorUnableToMoveReplacement = 1176;
        private const int ErrorUnableToMoveReplacement2 = 1177;
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

            Exception writeFailure = null;
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
            catch (Exception exception)
            {
                writeFailure = exception;
                throw;
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    try
                    {
                        File.Delete(temporaryPath);
                    }
                    catch (Exception) when (writeFailure != null)
                    {
                        // Preserve the publication failure. A cleanup error must
                        // not replace why no JSON document was published.
                    }
                }
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
            return win32Code == ErrorAccessDenied
                || win32Code == ErrorSharingViolation
                || win32Code == ErrorLockViolation
                || win32Code == ErrorUnableToRemoveReplaced
                || win32Code == ErrorUnableToMoveReplacement
                || win32Code == ErrorUnableToMoveReplacement2;
        }
    }
}
