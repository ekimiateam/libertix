using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;

namespace Libertix.Installation
{
    /// <summary>
    /// Validates a complete static IPv4 profile without assuming a laboratory subnet.
    /// </summary>
    public static class Ipv4NetworkPolicy
    {
        public static bool TryValidate(
            string addressText,
            int prefixLength,
            string gatewayText,
            IEnumerable<string> dnsServerTexts,
            out string normalizedAddress,
            out string normalizedGateway,
            out IReadOnlyList<string> normalizedDnsServers,
            out string error)
        {
            normalizedAddress = null;
            normalizedGateway = null;
            normalizedDnsServers = Array.Empty<string>();
            error = null;

            if (!TryParseIpv4(addressText, out IPAddress address))
                return Fail("The static address must be IPv4.", out error);
            if (!IsUnicastConfigurationAddress(address))
                return Fail(
                    "The static address cannot be unspecified, loopback, link-local, multicast or reserved.",
                    out error);
            if (prefixLength < 1 || prefixLength > 30)
                return Fail("The IPv4 prefix length must be between 1 and 30.", out error);
            if (!TryParseIpv4(gatewayText, out IPAddress gateway))
                return Fail("The gateway must be IPv4.", out error);
            if (!IsUnicastConfigurationAddress(gateway))
                return Fail(
                    "The gateway cannot be unspecified, loopback, link-local, multicast or reserved.",
                    out error);

            uint mask = uint.MaxValue << (32 - prefixLength);
            uint addressValue = ToUInt32(address);
            uint gatewayValue = ToUInt32(gateway);
            uint network = addressValue & mask;
            uint broadcast = network | ~mask;
            if (addressValue == network || addressValue == broadcast)
                return Fail("The static address cannot be the subnet or broadcast address.", out error);
            if ((gatewayValue & mask) != network ||
                gatewayValue == network ||
                gatewayValue == broadcast ||
                gatewayValue == addressValue)
            {
                return Fail("The gateway must be a different usable address in the same subnet.", out error);
            }

            var dnsServers = new List<string>();
            foreach (string dnsServerText in dnsServerTexts ?? Enumerable.Empty<string>())
            {
                if (!TryParseIpv4(dnsServerText, out IPAddress dnsServer))
                    return Fail("Every DNS server must be IPv4.", out error);
                string normalizedDns = dnsServer.ToString();
                if (!dnsServers.Contains(normalizedDns, StringComparer.Ordinal))
                    dnsServers.Add(normalizedDns);
            }
            if (dnsServers.Count == 0)
                return Fail("At least one DNS server is required.", out error);

            normalizedAddress = address.ToString();
            normalizedGateway = gateway.ToString();
            normalizedDnsServers = dnsServers;
            return true;
        }

        private static bool TryParseIpv4(string value, out IPAddress address)
        {
            return IPAddress.TryParse(value, out address) &&
                address.AddressFamily == AddressFamily.InterNetwork;
        }

        private static uint ToUInt32(IPAddress address)
        {
            byte[] octets = address.GetAddressBytes();
            return ((uint)octets[0] << 24) |
                ((uint)octets[1] << 16) |
                ((uint)octets[2] << 8) |
                octets[3];
        }

        private static bool IsUnicastConfigurationAddress(IPAddress address)
        {
            byte[] octets = address.GetAddressBytes();
            return octets[0] != 0 &&
                octets[0] != 127 &&
                !(octets[0] == 169 && octets[1] == 254) &&
                octets[0] < 224;
        }

        private static bool Fail(string message, out string error)
        {
            error = message;
            return false;
        }
    }
}
