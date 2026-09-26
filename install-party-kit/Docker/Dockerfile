FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Helpers/ Helpers/
COPY Models/DistroInfoJson.cs Models/DistroInfoJson.cs
COPY Installation/CatalogFiles.cs Installation/CatalogFiles.cs
COPY Installation/DistributionCatalogTrust.cs Installation/DistributionCatalogTrust.cs
COPY Scripts/config/Libertix.CatalogPublicKey.xml Scripts/config/Libertix.CatalogPublicKey.xml
COPY install-party-kit/Server/ install-party-kit/Server/
RUN dotnet publish install-party-kit/Server/Libertix.InstallParty.csproj -c Release -o /publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /publish/ ./
RUN mkdir /data && chown "$APP_UID:$APP_UID" /data
USER $APP_UID
VOLUME /data
ENTRYPOINT ["dotnet", "Libertix.InstallParty.dll", "--state", "/data"]
