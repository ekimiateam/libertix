using System;
using System.Net;
using System.Net.Sockets;

namespace Libertix.Helpers
{
    public sealed class StartupOptions
    {
        private const string FilepoolOption = "--filepool-base-url";
        private const string DevelopmentSshStaticIpOption = "--dev-ssh-static-ip";

        public string FilepoolBaseUrlOverride { get; private set; }
        public string DevelopmentSshStaticIpv4Address { get; private set; }

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

                    if (!TryNormalizeDevelopmentIpv4Address(value, out string address))
                    {
                        error = DevelopmentSshStaticIpOption +
                            " requires a usable address in 192.168.1.0/24.";
                        return false;
                    }

                    options.DevelopmentSshStaticIpv4Address = address;
                }
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

        private static bool TryNormalizeDevelopmentIpv4Address(
            string value,
            out string normalized)
        {
            normalized = null;
            if (!IPAddress.TryParse(value, out IPAddress address) ||
                address.AddressFamily != AddressFamily.InterNetwork)
            {
                return false;
            }

            byte[] octets = address.GetAddressBytes();
            if (octets[0] != 192 || octets[1] != 168 || octets[2] != 1 ||
                octets[3] <= 1 || octets[3] >= 255)
            {
                return false;
            }

            normalized = address.ToString();
            return true;
        }
    }
}
