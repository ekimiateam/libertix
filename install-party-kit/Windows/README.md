# Windows console server

Build with the .NET 10 SDK, from the repository root:

```powershell
dotnet publish .\install-party-kit\Server\Libertix.InstallParty.csproj `
  -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true `
  -o .\install-party-kit\Server\bin\windows
```

Copy the complete publish directory, including `wwwroot`, to the server. No SDK is needed there.
From that directory:

```powershell
.\Libertix.InstallParty.exe --state "$env:LOCALAPPDATA\LibertixInstallParty"
```

Open **http://127.0.0.1:18080/** on that PC. Leave the console open. Progress and configuration are
on the local web page. Settings and downloaded files persist under the state directory; do not place
it in a public writable share.

Allow this executable on the Windows Firewall private network profile, with inbound UDP 18081 and
TCP 18080 (or your configured HTTP port). Do not enable public-network or Internet access. The
page and management APIs are available only over loopback; LAN clients can only fetch artifacts
and discover the service. Discovery requires a common IPv4 broadcast network without client isolation.

Settings changes apply after you stop the console with Ctrl+C and start the same command again.
Wait until transfers finish before restarting. Do not run two instances against the same storage.

See [operation, trust and the separate folder-only mode](../README.md).
