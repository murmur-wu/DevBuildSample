# 基底 image 以 digest 鎖定：平常部署只需下載幾 MB 的程式層；更新由 Dependabot 開 PR（.github/dependabot.yml）
FROM golang:1.27-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
# 靜態連結（CGO_ENABLED=0），執行階段不需要任何函式庫
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /api .

# alpine 內建 busybox wget，healthcheck 用得到
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
COPY --from=build /api /usr/local/bin/api
# 不以 root 執行
RUN adduser -D -H -u 10001 app
USER app
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["api"]
