using System;

namespace Libertix.Helpers
{
    internal sealed class StartupOptions
    {
        private const string FilepoolOption = "--filepool-base-url";

        public string FilepoolBaseUrlOverride { get; private set; }

        public static bool TryParse(string[] args, out StartupOptions options, out string error)
        {
            options = new StartupOptions();
            error = null;

            if (args == null)
                return true;

            for (int index = 0; index < args.Length; index++)
            {
                if (!string.Equals(args[index], FilepoolOption, StringComparison.OrdinalIgnoreCase))
                    continue;

                if (!string.IsNullOrEmpty(options.FilepoolBaseUrlOverride))
                {
                    error = FilepoolOption + " can only be specified once.";
                    return false;
                }

                if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
                {
                    error = FilepoolOption + " requires an HTTP(S) URL.";
                    return false;
                }

                options.FilepoolBaseUrlOverride = args[++index];
            }

            return true;
        }
    }
}
