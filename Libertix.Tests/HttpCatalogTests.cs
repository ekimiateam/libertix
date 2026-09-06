using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Libertix.Helpers;
using Libertix.Installation;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Libertix.Tests
{
    [TestClass]
    public sealed class HttpCatalogTests
    {
        [DataTestMethod]
        [DataRow(false)]
        [DataRow(true)]
        public async Task RejectsOversizedCatalogWithoutWaitingForTheBodyToFinish(bool chunked)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var release = new ManualResetEventSlim(false);
            var headersSent = new TaskCompletionSource<bool>();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Task server = Task.Run(() =>
            {
                try
                {
                    using (TcpClient peer = listener.AcceptTcpClient())
                    using (NetworkStream stream = peer.GetStream())
                    {
                        stream.ReadTimeout = 5000;
                        stream.WriteTimeout = 5000;
                        var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                        while (!string.IsNullOrEmpty(reader.ReadLine())) { }
                        string headers = "HTTP/1.1 200 OK\r\nConnection: close\r\n" +
                            (chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: 2097152\r\n") + "\r\n";
                        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
                        stream.Write(headerBytes, 0, headerBytes.Length);
                        headersSent.TrySetResult(true);
                        if (chunked)
                        {
                            byte[] size = Encoding.ASCII.GetBytes("100001\r\n");
                            stream.Write(size, 0, size.Length);
                            byte[] body = new byte[1024 * 1024 + 1];
                            stream.Write(body, 0, body.Length);
                            stream.Write(new byte[] { 13, 10 }, 0, 2);
                        }
                        stream.Flush();
                        release.Wait(TimeSpan.FromSeconds(10));
                    }
                }
                catch (IOException) { }
                catch (SocketException) { }
            });
            try
            {
                Assert.IsTrue(FilepoolConfig.TryCreate("http://127.0.0.1:" + port, out FilepoolConfig pool, out _));
                Task load = DistributionCatalogLoader.LoadAsync(pool);
                Assert.AreSame(headersSent.Task, await Task.WhenAny(headersSent.Task, Task.Delay(TimeSpan.FromSeconds(10))),
                    "The local HTTP server did not send the response headers.");
                Assert.AreSame(load, await Task.WhenAny(load, Task.Delay(TimeSpan.FromSeconds(5))),
                    "The size guard must not buffer the unfinished response first.");
                InvalidDataException error = await Assert.ThrowsExceptionAsync<InvalidDataException>(async () => await load);
                StringAssert.Contains(error.Message, "exceeds");
            }
            finally
            {
                release.Set();
                listener.Stop();
                await server;
                release.Dispose();
            }
        }
    }
}
