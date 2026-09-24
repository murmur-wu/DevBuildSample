# 基底 image 以 digest 鎖定：平常部署只需下載幾 KB 的程式層；更新由 Dependabot 開 PR（.github/dependabot.yml）
# alpine 版內建 busybox wget，healthcheck 用得到；套件都有 musllinux 的預編譯版本，不需要編譯器
FROM python:3.14-alpine@sha256:9e9fde4d32eedce0b661d9ab91e826b62dddf28e928c230ec55f1866cac66b01

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --only-binary=:all: -r requirements.txt
COPY app/ app/

# 不以 root 執行
RUN adduser -D -H -u 10001 app
USER app

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
# 先建立資料表（DB 未就緒會重試），再以 uvicorn 取代本程序（見 app/entrypoint.py）
CMD ["python", "-m", "app.entrypoint"]
