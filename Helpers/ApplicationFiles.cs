using System;
using System.IO;
using System.Linq;

namespace Libertix.Helpers
{
    /// <summary>Resolves files shipped next to Libertix.exe.</summary>
    internal static class ApplicationFiles
    {
        public static string Resolve(params string[] relativeParts)
        {
            return Path.Combine(
                new[] { AppDomain.CurrentDomain.BaseDirectory }.Concat(relativeParts).ToArray());
        }
    }
}
