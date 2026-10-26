# 基底 image 以 digest 鎖定：平常部署只需下載幾 KB 的程式層；更新由 Dependabot 開 PR（.github/dependabot.yml）
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:afd0ccff9d306812a69ef0f47458376b6acb544ae866cfc4b8d28ff0eef35ea7 AS build
WORKDIR /src
COPY src/Api/Api.csproj src/Api/
RUN dotnet restore src/Api/Api.csproj
COPY src/Api/ src/Api/
RUN dotnet publish src/Api/Api.csproj -c Release -o /app --no-restore

# alpine 版內建 busybox wget，healthcheck 用得到；標準 aspnet image 沒有 curl/wget
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine@sha256:254fe017495996d3abcc487ffacdcce2b73affb380d3af87af12c8dff41fe0b0
WORKDIR /app
COPY --from=build /app .
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
# 容器內固定聽 8080（.NET 8 起的預設），對外 port 由 compose 對應
ENV ASPNETCORE_HTTP_PORTS=8080
USER $APP_UID
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["dotnet", "Api.dll"]
