using System;
using System.Collections.Generic;
using System.Globalization;
using Libertix.Installation;

namespace Libertix.Helpers
{
    public sealed class StartupOptions
    {
        private const string FilepoolOption = "--filepool-base-url";
        private const string LocalFilepoolOption = "--local-filepool-dir";
        private const string DevelopmentModeOption = "--dev";
        private const string DevelopmentSshStaticIpOption = "--dev-ssh-static-ip";
        private const string DevelopmentSshPrefixLengthOption = "--dev-ssh-prefix-length";
        private const string DevelopmentSshGatewayOption = "--dev-ssh-gateway";
        private const string DevelopmentSshDnsOption = "--dev-ssh-dns";
        private const string SkipNvramWriteProbeOption = "--skip-nvram-write-probe";
        private const string UefiBootNextFailedOption = "--uefi-bootnext-failed";
        private const string UefiRecoveryStateOption = "--uefi-recovery-state";
        private const string UnattendedOption = "--unattended";
        private const string UnattendedConfigOption = "--unattended-config";
        private const string ForceOfflineNtfsResizeOption = "--force-offline-ntfs-resize";

        public string FilepoolBaseUrlOverride { get; private set; }
        public string LocalFilepoolDirectory { get; private set; }
        public bool DevelopmentMode { get; private set; }
        public string DevelopmentSshStaticIpv4Address { get; private set; }
        public int? DevelopmentSshStaticIpv4PrefixLength { get; private set; }
        public string DevelopmentSshStaticIpv4Gateway { get; private set; }
        public IReadOnlyList<string> DevelopmentSshDnsServers { get; private set; } =
            Array.Empty<string>();
        public bool SkipNvramWriteProbe { get; private set; }
        public bool UefiBootNextFailed { get; private set; }
        public string UefiRecoveryStatePath { get; private set; }
        public UnattendedOptions Unattended { get; private set; }
        public bool ForceOfflineNtfsResize { get; private set; }

        internal bool TryValidateBuild(ApplicationBuild build, out string error)
        {
            error = null;
            if (!build.IsDevelopment && !string.IsNullOrEmpty(DevelopmentSshStaticIpv4Address))
            {
                error = "Development SSH networking is available only in development builds.";
                return false;
            }
            return true;
        }

        private bool UnattendedRequested { get; set; }
        private string UnattendedConfigPath { get; set; }

        internal void CompleteUnattendedWorkflow()
        {
            Unattended?.ClearPassword();
            Unattended = null;
        }

        private delegate bool OptionHandler(
            StartupOptions options,
            string[] args,
            ref int index,
            out string error);

        private static readonly Dictionary<string, OptionHandler> OptionHandlers =
            new Dictionary<string, OptionHandler>(StringComparer.OrdinalIgnoreCase)
            {
                [FilepoolOption] = SingleValue(
                    FilepoolOption,
                    options => options.FilepoolBaseUrlOverride,
                    (options, value) => options.FilepoolBaseUrlOverride = value),
                [LocalFilepoolOption] = SingleValue(
                    LocalFilepoolOption,
                    options => options.LocalFilepoolDirectory,
                    (options, value) => options.LocalFilepoolDirectory = value),
                [DevelopmentModeOption] = OnceFlag(
                    DevelopmentModeOption,
                    options => options.DevelopmentMode,
                    options => options.DevelopmentMode = true),
                [DevelopmentSshStaticIpOption] = SingleValue(
                    DevelopmentSshStaticIpOption,
                    options => options.DevelopmentSshStaticIpv4Address,
                    (options, value) => options.DevelopmentSshStaticIpv4Address = value),
                [DevelopmentSshPrefixLengthOption] = SingleParsedValue(
                    DevelopmentSshPrefixLengthOption,
                    options => options.DevelopmentSshStaticIpv4PrefixLength?.ToString(
                        CultureInfo.InvariantCulture),
                    SetDevelopmentSshPrefixLength),
                [DevelopmentSshGatewayOption] = SingleValue(
                    DevelopmentSshGatewayOption,
                    options => options.DevelopmentSshStaticIpv4Gateway,
                    (options, value) => options.DevelopmentSshStaticIpv4Gateway = value),
                [DevelopmentSshDnsOption] = RepeatableValue(
                    DevelopmentSshDnsOption,
                    "requires an IPv4 address.",
                    (options, value) => options.DevelopmentSshDnsServers =
                        new List<string>(options.DevelopmentSshDnsServers) { value }),
                [SkipNvramWriteProbeOption] = OnceFlag(
                    SkipNvramWriteProbeOption,
                    options => options.SkipNvramWriteProbe,
                    options => options.SkipNvramWriteProbe = true),
                [UefiBootNextFailedOption] = RepeatableFlag(
                    options => options.UefiBootNextFailed = true),
                [UefiRecoveryStateOption] = RepeatableValue(
                    UefiRecoveryStateOption,
                    "requires a state-file path.",
                    (options, value) => options.UefiRecoveryStatePath = value),
                [UnattendedOption] = OnceFlag(
                    UnattendedOption,
                    options => options.UnattendedRequested,
                    options => options.UnattendedRequested = true),
                [UnattendedConfigOption] = SingleValue(
                    UnattendedConfigOption,
                    options => options.UnattendedConfigPath,
                    (options, value) => options.UnattendedConfigPath = value),
                [ForceOfflineNtfsResizeOption] = OnceFlag(
                    ForceOfflineNtfsResizeOption,
                    options => options.ForceOfflineNtfsResize,
                    options => options.ForceOfflineNtfsResize = true),
            };

        public static bool TryParse(string[] args, out StartupOptions options, out string error)
        {
            options = new StartupOptions();
            error = null;

            if (args == null)
                return true;

            for (int index = 0; index < args.Length; index++)
            {
                string option = args[index];
                // Ignoring a misspelled safety or development option can run a
                // materially different workflow from the one the caller
                // requested. Reject every option outside the explicit contract.
                if (!OptionHandlers.TryGetValue(option, out OptionHandler handler))
                {
                    error = "Unknown Libertix option: " + option;
                    return false;
                }
                if (!handler(options, args, ref index, out error))
                    return false;
            }

            if (!options.ValidateDevelopmentNetwork(out error))
                return false;

            bool hasUnattendedConfig = !string.IsNullOrWhiteSpace(options.UnattendedConfigPath);
            if (options.UnattendedRequested != hasUnattendedConfig)
            {
                error = UnattendedOption + " and " + UnattendedConfigOption +
                    " must be specified together.";
                return false;
            }
            if (options.UnattendedRequested)
            {
                if (!UnattendedOptions.TryLoad(
                    options.UnattendedConfigPath,
                    out UnattendedOptions unattended,
                    out error))
                {
                    return false;
                }
                options.Unattended = unattended;
            }
            return true;
        }

        private static OptionHandler OnceFlag(
            string option,
            Func<StartupOptions, bool> isSet,
            Action<StartupOptions> set)
        {
            return (StartupOptions options, string[] args, ref int index, out string error) =>
            {
                error = isSet(options) ? option + " can only be specified once." : null;
                if (error != null)
                    return false;
                set(options);
                return true;
            };
        }

        private static OptionHandler RepeatableFlag(Action<StartupOptions> set)
        {
            return (StartupOptions options, string[] args, ref int index, out string error) =>
            {
                error = null;
                set(options);
                return true;
            };
        }

        /// <summary>Reads the next argument once; <paramref name="apply"/> returns an error or null.</summary>
        private static OptionHandler SingleParsedValue(
            string option,
            Func<StartupOptions, string> existingValue,
            Func<StartupOptions, string, string> apply)
        {
            return (StartupOptions options, string[] args, ref int index, out string error) =>
            {
                if (!string.IsNullOrEmpty(existingValue(options)))
                {
                    error = option + " can only be specified once.";
                    return false;
                }
                if (!TryReadNextValue(args, ref index, option + " requires a value.", out string value, out error))
                    return false;
                error = apply(options, value);
                return error == null;
            };
        }

        private static OptionHandler SingleValue(
            string option,
            Func<StartupOptions, string> existingValue,
            Action<StartupOptions, string> set)
        {
            return SingleParsedValue(option, existingValue, (options, value) =>
            {
                set(options, value);
                return null;
            });
        }

        private static OptionHandler RepeatableValue(
            string option,
            string requirement,
            Action<StartupOptions, string> set)
        {
            return (StartupOptions options, string[] args, ref int index, out string error) =>
            {
                if (!TryReadNextValue(args, ref index, option + " " + requirement, out string value, out error))
                    return false;
                set(options, value);
                return true;
            };
        }

        private static bool TryReadNextValue(
            string[] args,
            ref int index,
            string missingValueError,
            out string value,
            out string error)
        {
            value = null;
            error = null;
            if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
            {
                error = missingValueError;
                return false;
            }

            value = args[++index];
            return true;
        }

        private static string SetDevelopmentSshPrefixLength(StartupOptions options, string value)
        {
            if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int prefixLength))
                return DevelopmentSshPrefixLengthOption + " requires an integer between 1 and 30.";
            options.DevelopmentSshStaticIpv4PrefixLength = prefixLength;
            return null;
        }

        private bool ValidateDevelopmentNetwork(out string error)
        {
            error = null;
            bool hasAddress = !string.IsNullOrWhiteSpace(DevelopmentSshStaticIpv4Address);
            bool hasPrefix = DevelopmentSshStaticIpv4PrefixLength.HasValue;
            bool hasGateway = !string.IsNullOrWhiteSpace(DevelopmentSshStaticIpv4Gateway);
            bool hasDns = DevelopmentSshDnsServers.Count > 0;
            if (!hasAddress && !hasPrefix && !hasGateway && !hasDns)
                return true;

            if (!hasAddress || !hasPrefix || !hasGateway || !hasDns)
            {
                error = "Development SSH networking requires --dev-ssh-static-ip, " +
                    "--dev-ssh-prefix-length, --dev-ssh-gateway and at least one --dev-ssh-dns.";
                return false;
            }

            if (!Ipv4NetworkPolicy.TryValidate(
                DevelopmentSshStaticIpv4Address,
                DevelopmentSshStaticIpv4PrefixLength.Value,
                DevelopmentSshStaticIpv4Gateway,
                DevelopmentSshDnsServers,
                out string normalizedAddress,
                out string normalizedGateway,
                out IReadOnlyList<string> normalizedDnsServers,
                out error))
            {
                return false;
            }

            DevelopmentSshStaticIpv4Address = normalizedAddress;
            DevelopmentSshStaticIpv4Gateway = normalizedGateway;
            DevelopmentSshDnsServers = normalizedDnsServers;
            return true;
        }
    }
}
