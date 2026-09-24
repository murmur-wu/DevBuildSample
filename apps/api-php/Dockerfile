# 基底 image 以 digest 鎖定：平常部署只需下載幾 KB 的程式層；更新由 Dependabot 開 PR（.github/dependabot.yml）
# FrankenPHP：內建 Caddy 的 PHP 伺服器，一個容器就能跑，不需要另外的 nginx + php-fpm
FROM dunglas/frankenphp:1-php8.5-alpine@sha256:9e181333b716364b338d5dc0e7e4b2ea22b68fa5907aaea6c8e96ff1ca4484e6

# 官方 image 沒有 PostgreSQL 驅動；install-php-extensions 是 image 內建的安裝工具
RUN install-php-extensions pdo_pgsql \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY docker/php.ini $PHP_INI_DIR/conf.d/zz-app.ini
COPY docker/Caddyfile /etc/frankenphp/Caddyfile
COPY docker/entrypoint.sh /usr/local/bin/app-entrypoint

WORKDIR /app
COPY bin/ bin/
COPY src/ src/
COPY public/ public/

# 不以 root 執行；Caddy 的資料目錄要可寫
RUN adduser -D -H -u 10001 app && chown -R app:app /data/caddy /config/caddy
USER app

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["app-entrypoint"]
