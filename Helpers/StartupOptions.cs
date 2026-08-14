using System;
using System.Collections.Generic;
using System.Globalization;
using Libertix.Installation;

namespace Libertix.Helpers
{
    public sealed class StartupOptions
    {
        private const string FilepoolOption = "--filepool-base-url";
        private const string DevelopmentSshStaticIpOption = "--dev-ssh-static-ip";
        private const string DevelopmentSshPrefixLengthOption = "--dev-ssh-prefix-length";
        private const string DevelopmentSshGatewayOption = "--dev-ssh-gateway";
        private const string DevelopmentSshDnsOption = "--dev-ssh-dns";
        private const string SkipNvramWriteProbeOption = "--skip-nvram-write-probe";
        private const string UefiBootNextFailedOption = "--uefi-bootnext-failed";
        private const string UefiRecoveryStateOption = "--uefi-recovery-state";
        private const string UnattendedOption = "--unattended";
        private const string UnattendedConfigOption = "--unattended-config";

        public string FilepoolBaseUrlOverride { get; private set; }
        public string DevelopmentSshStaticIpv4Address { get; private set; }
        public int? DevelopmentSshStaticIpv4PrefixLength { get; private set; }
        public string DevelopmentSshStaticIpv4Gateway { get; private set; }
        public IReadOnlyList<string> DevelopmentSshDnsServers { get; private set; } =
            Array.Empty<string>();
        public bool SkipNvramWriteProbe { get; private set; }
        public bool UefiBootNextFailed { get; private set; }
        public string UefiRecoveryStatePath { get; private set; }
        public UnattendedOptions Unattended { get; private set; }
        private bool UnattendedRequested { get; set; }
        private string UnattendedConfigPath { get; set; }

        internal void CompleteUnattendedWorkflow()
        {
            Unattended?.ClearPassword();
            Unattended = null;
        }

        public static bool TryParse(string[] args, out StartupOptions options, out string error)
        {
            options = new StartupOptions();
            error = null;

            if (args == null)
                return true;

            for (int index = 0; index < args.Length; index++)
            {
                string option = args[index];
                if (string.Equals(option, FilepoolOption, StringComparison.OrdinalIgnoreCase))
                {
                    if (!TryReadSingleValue(
                        args,
                        ref index,
                        FilepoolOption,
                        options.FilepoolBaseUrlOverride,
                        out string value,
                        out error))
                    {
                        return false;
                    }

                    options.FilepoolBaseUrlOverride = value;
                    continue;
                }

                if (string.Equals(
                    option,
                    DevelopmentSshStaticIpOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (!TryReadSingleValue(
                        args,
                        ref index,
                        DevelopmentSshStaticIpOption,
                        options.DevelopmentSshStaticIpv4Address,
                        out string value,
                        out error))
                    {
                        return false;
                    }

                    options.DevelopmentSshStaticIpv4Address = value;
                    continue;
                }

                if (string.Equals(
                    option,
                    DevelopmentSshPrefixLengthOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (!TryReadSingleValue(
                        args,
                        ref index,
                        DevelopmentSshPrefixLengthOption,
                        options.DevelopmentSshStaticIpv4PrefixLength?.ToString(
                            CultureInfo.InvariantCulture),
                        out string value,
                        out error))
                    {
                        return false;
                    }

                    if (!int.TryParse(
                        value,
                        NumberStyles.None,
                        CultureInfo.InvariantCulture,
                        out int prefixLength))
                    {
                        error = DevelopmentSshPrefixLengthOption +
                            " requires an integer between 1 and 30.";
                        return false;
                    }

                    options.DevelopmentSshStaticIpv4PrefixLength = prefixLength;
                    continue;
                }

                if (string.Equals(
                    option,
                    DevelopmentSshGatewayOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (!TryReadSingleValue(
                        args,
                        ref index,
                        DevelopmentSshGatewayOption,
                        options.DevelopmentSshStaticIpv4Gateway,
                        out string value,
                        out error))
                    {
                        return false;
                    }

                    options.DevelopmentSshStaticIpv4Gateway = value;
                    continue;
                }

                if (string.Equals(
                    option,
                    DevelopmentSshDnsOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
                    {
                        error = DevelopmentSshDnsOption + " requires an IPv4 address.";
                        return false;
                    }

                    var dnsServers = new List<string>(options.DevelopmentSshDnsServers)
                    {
                        args[++index]
                    };
                    options.DevelopmentSshDnsServers = dnsServers;
                    continue;
                }

                if (string.Equals(
                    option,
                    SkipNvramWriteProbeOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (options.SkipNvramWriteProbe)
                    {
                        error = SkipNvramWriteProbeOption + " can only be specified once.";
                        return false;
                    }

                    options.SkipNvramWriteProbe = true;
                    continue;
                }

                if (string.Equals(
                    option,
                    UefiBootNextFailedOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    options.UefiBootNextFailed = true;
                    continue;
                }

                if (string.Equals(
                    option,
                    UefiRecoveryStateOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
                    {
                        error = UefiRecoveryStateOption + " requires a state-file path.";
                        return false;
                    }

                    options.UefiRecoveryStatePath = args[++index];
                    continue;
                }

                if (string.Equals(option, UnattendedOption, StringComparison.OrdinalIgnoreCase))
                {
                    if (options.UnattendedRequested)
                    {
                        error = UnattendedOption + " can only be specified once.";
                        return false;
                    }
                    options.UnattendedRequested = true;
                    continue;
                }

                if (string.Equals(
                    option,
                    UnattendedConfigOption,
                    StringComparison.OrdinalIgnoreCase))
                {
                    if (!TryReadSingleValue(
                        args,
                        ref index,
                        UnattendedConfigOption,
                        options.UnattendedConfigPath,
                        out string value,
                        out error))
                    {
                        return false;
                    }
                    options.UnattendedConfigPath = value;
                    continue;
                }

                // Ignoring a misspelled safety or development option can run a
                // materially different workflow from the one the caller
                // requested. Reject every option outside the explicit contract.
                error = "Unknown Libertix option: " + option;
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

        private static bool TryReadSingleValue(
            string[] args,
            ref int index,
            string option,
            string existingValue,
            out string value,
            out string error)
        {
            value = null;
            error = null;
            if (!string.IsNullOrEmpty(existingValue))
            {
                error = option + " can only be specified once.";
                return false;
            }

            if (index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1]))
            {
                error = option + " requires a value.";
                return false;
            }

            value = args[++index];
            return true;
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
