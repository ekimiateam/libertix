using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace Libertix.Helpers
{
    public static class LocalFilepoolDiscovery
    {
        private const int ReceiveTimeoutMilliseconds = 300;
        private const int MaximumReplyBytes = 256;
        private static readonly TimeSpan DiscoveryTimeout = TimeSpan.FromSeconds(3);

        public static Task<IReadOnlyList<string>> FindAsync(string channel)
        {
            return Task.Run<IReadOnlyList<string>>(() =>
            {
                string nonce = Guid.NewGuid().ToString("N");
                byte[] query = Encoding.ASCII.GetBytes(
                    FilepoolProtocol.DiscoveryRequest + "|" + nonce + "|" + channel);
                using (var socket = new UdpClient(AddressFamily.InterNetwork))
                {
                    socket.EnableBroadcast = true;
                    socket.Client.ReceiveTimeout = ReceiveTimeoutMilliseconds;
                    foreach (var address in GetBroadcastAddresses())
                        socket.Send(query, query.Length, new IPEndPoint(address, FilepoolProtocol.DiscoveryPort));
                    return ReceiveServers(socket, nonce, channel);
                }
            });
        }

        private static IEnumerable<IPAddress> GetBroadcastAddresses()
        {
            var broadcasts = new HashSet<IPAddress> { IPAddress.Broadcast };
            foreach (var network in NetworkInterface.GetAllNetworkInterfaces()
                .Where(item => item.OperationalStatus == OperationalStatus.Up))
            {
                foreach (var unicast in network.GetIPProperties().UnicastAddresses
                    .Where(item => item.Address.AddressFamily == AddressFamily.InterNetwork &&
                        !IPAddress.IsLoopback(item.Address)))
                {
                    byte[] ip = unicast.Address.GetAddressBytes();
                    byte[] mask = unicast.IPv4Mask.GetAddressBytes();
                    broadcasts.Add(new IPAddress(ip.Select((part, i) =>
                        (byte)(part | ~mask[i])).ToArray()));
                }
            }
            return broadcasts;
        }

        private static IReadOnlyList<string> ReceiveServers(UdpClient socket, string nonce, string channel)
        {
            var servers = new SortedSet<string>(StringComparer.Ordinal);
            var timer = Stopwatch.StartNew();
            while (timer.Elapsed < DiscoveryTimeout)
            {
                var sender = new IPEndPoint(IPAddress.Any, 0);
                byte[] response;
                try
                {
                    response = socket.Receive(ref sender);
                }
                catch (SocketException error) when (error.SocketErrorCode == SocketError.TimedOut)
                {
                    continue;
                }
                if (response.Length > MaximumReplyBytes)
                    continue;

                string[] parts = Encoding.ASCII.GetString(response).Split('|');
                int port;
                if (parts.Length == 4 && parts[0] == FilepoolProtocol.DiscoveryRequest &&
                    parts[1] == nonce && parts[2] == channel &&
                    int.TryParse(parts[3], out port) && port > 0 && port <= IPEndPoint.MaxPort)
                    servers.Add(new UriBuilder("https", sender.Address.ToString(), port)
                        .Uri.GetLeftPart(UriPartial.Authority));
            }
            return servers.ToArray();
        }
    }
}
