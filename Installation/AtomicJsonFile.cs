using System;
using System.IO;
using System.Text;

namespace Libertix.Installation
{
    /// <summary>
    /// Publishes UTF-8 JSON with a same-directory atomic rename. Readers either
    /// see the previous complete document or the new complete document.
    /// </summary>
    internal static class AtomicJsonFile
    {
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

                if (File.Exists(fullPath))
                    File.Replace(temporaryPath, fullPath, null);
                else
                    File.Move(temporaryPath, fullPath);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }
    }
}
