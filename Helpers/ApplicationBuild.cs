using System;
using System.Reflection;
using System.Text.RegularExpressions;

namespace Libertix.Helpers
{
    public sealed class ApplicationBuild
    {
        public const string GitHubPagesBaseUrl = "https://ekimiateam.github.io/libertix";
        private static readonly Regex DevelopmentVersionPattern = new Regex(
            "^dev_(?<tag>[0-9a-f]{7})$",
            RegexOptions.CultureInvariant);
        private static readonly Regex StableVersionPattern = new Regex(
            "^(?:0|[1-9][0-9]*)(?:\\.(?:0|[1-9][0-9]*)){1,2}(?:-[0-9A-Za-z.-]+)?$",
            RegexOptions.CultureInvariant);

        private ApplicationBuild(string version, string channel, string releaseTag)
        {
            Version = version;
            Channel = channel;
            ReleaseTag = releaseTag;
        }

        public string Version { get; }

        public string Channel { get; }

        public string ReleaseTag { get; }

        public bool IsDevelopment => string.Equals(
            Channel,
            "dev",
            StringComparison.Ordinal);

        public bool RequiresPublishedVersionCheck => !IsDevelopment;

        public string MetadataBaseUrl => GitHubPagesBaseUrl + "/" + Channel;

        public static ApplicationBuild Current { get; } = Parse(
            typeof(ApplicationBuild).Assembly
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
                ?.InformationalVersion);

        public static ApplicationBuild Parse(string version)
        {
            if (string.IsNullOrWhiteSpace(version))
                throw new InvalidOperationException("The Libertix build version is missing.");

            Match development = DevelopmentVersionPattern.Match(version);
            if (development.Success)
            {
                return new ApplicationBuild(
                    version,
                    "dev",
                    development.Groups["tag"].Value);
            }

            if (StableVersionPattern.IsMatch(version))
                return new ApplicationBuild(version, "main", version);

            throw new InvalidOperationException(
                "The Libertix build version must be dev_<sha7> or a stable release number.");
        }
    }
}
