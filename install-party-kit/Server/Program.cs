using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using Libertix.Helpers;
using Libertix.InstallParty;

const int MaximumRequestBodyBytes = 16 * 1024;
const int MaximumDiscoveryRequestBytes = 128;
var builder = WebApplication.CreateBuilder(args);
string stateDirectory = Path.GetFullPath(builder.Configuration["state"] ??
    Path.Combine(AppContext.BaseDirectory, "state"));
Directory.CreateDirectory(stateDirectory);
var settings = KitSettings.Load(stateDirectory);
using var loggerFactory = LoggerFactory.Create(logging => logging.AddSimpleConsole());
var logger = loggerFactory.CreateLogger("InstallParty");
using var store = new FilepoolStore(settings, logger);
using var discovery = new UdpClient(new IPEndPoint(IPAddress.Any, FilepoolProtocol.DiscoveryPort));
var updates = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
{ SingleReader = true, FullMode = BoundedChannelFullMode.DropWrite });

builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = MaximumRequestBodyBytes;
    options.ListenAnyIP(settings.HttpPort);
});
var app = builder.Build();
app.Use(async (context, next) =>
{
    if (!context.Request.Path.StartsWithSegments("/files"))
    {
        if (!IsLocalManagementRequest(context))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
    }
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.ContentSecurityPolicy =
        "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
    await next(context);
});
app.UseDefaultFiles();
app.UseStaticFiles();
app.MapGet("/api/status", () => Results.Json(new
{
    settings,
    pendingSettings = KitSettings.Load(stateDirectory),
    discoveryPort = FilepoolProtocol.DiscoveryPort,
    addresses = LocalAddresses().Select(address =>
        new UriBuilder("http", address.ToString(), settings.HttpPort).Uri.AbsoluteUri),
    pool = store.Status()
}));
app.MapGet("/files/{hash}/{name}", store.ServeAsync);
app.MapPost("/api/update", () =>
{
    updates.Writer.TryWrite(true);
    return Results.Json(new { message = "Update requested." });
});
app.MapPost("/api/settings", (KitSettings requested) =>
{
    try
    {
        requested.Save(stateDirectory);
        return Results.Json(new { message = "Settings saved. Restart the server to apply them; current transfers are unchanged." });
    }
    catch (ArgumentException error) { return Results.BadRequest(error.Message); }
    catch (IOException error) { return Results.Problem(error.Message); }
    catch (UnauthorizedAccessException error) { return Results.Problem(error.Message); }
});

await app.StartAsync();
logger.LogInformation("Libertix install-party: HTTP {HttpPort}, UDP {DiscoveryPort}, channel {Channel}",
    settings.HttpPort, FilepoolProtocol.DiscoveryPort, settings.Channel);
using var stopping = CancellationTokenSource.CreateLinkedTokenSource(app.Lifetime.ApplicationStopping);
updates.Writer.TryWrite(true);
Task downloads = RunUpdatesAsync(stopping.Token);
Task announcements = RunDiscoveryAsync(stopping.Token);
try { await app.WaitForShutdownAsync(); }
finally
{
    stopping.Cancel();
    await Task.WhenAll(downloads, announcements);
}

async Task RunUpdatesAsync(CancellationToken token)
{
    try
    {
        await foreach (bool request in updates.Reader.ReadAllAsync(token))
            await store.UpdateAsync(token);
    }
    catch (OperationCanceledException) when (token.IsCancellationRequested) { }
}

static IPAddress[] LocalAddresses() => NetworkInterface.GetAllNetworkInterfaces()
    .Where(network => network.OperationalStatus == OperationalStatus.Up)
    .SelectMany(network => network.GetIPProperties().UnicastAddresses)
    .Select(item => item.Address)
    .Select(address => new IPAddress(address.GetAddressBytes()))
    .Append(IPAddress.Loopback).Append(IPAddress.IPv6Loopback)
    .Distinct().OrderBy(address => address.ToString(), StringComparer.Ordinal).ToArray();

static bool IsLocalManagementRequest(HttpContext context)
{
    IPAddress peer = context.Connection.RemoteIpAddress;
    string host = context.Request.Host.Host;
    bool localHost = host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
        (IPAddress.TryParse(host.Trim('[', ']'), out var address) && IPAddress.IsLoopback(address));
    if (peer == null || !IPAddress.IsLoopback(peer.IsIPv4MappedToIPv6 ? peer.MapToIPv4() : peer) ||
        !localHost)
        return false;

    // The custom header forces browser cross-origin writes through a CORS
    // preflight, which this local-only interface never authorizes.
    return !HttpMethods.IsPost(context.Request.Method) || context.Request.Headers["X-Libertix-Request"] == "1";
}

async Task RunDiscoveryAsync(CancellationToken token)
{
    try
    {
        while (!token.IsCancellationRequested)
        {
            var packet = await discovery.ReceiveAsync(token);
            if (packet.Buffer.Length > MaximumDiscoveryRequestBytes || !store.Ready)
                continue;
            string[] fields = Encoding.ASCII.GetString(packet.Buffer).Split('|');
            if (fields.Length != 3 || fields[0] != FilepoolProtocol.DiscoveryRequest ||
                !Guid.TryParseExact(fields[1], "N", out _) || fields[2] != settings.Channel)
                continue;
            byte[] reply = Encoding.ASCII.GetBytes(string.Join("|", fields) + "|" + settings.HttpPort);
            await discovery.SendAsync(reply, packet.RemoteEndPoint, token);
        }
    }
    catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    catch (SocketException error)
    {
        logger.LogError(error, "UDP discovery failed; restart the server after resolving the network error");
        app.Lifetime.StopApplication();
    }
}
