# 基底 image 以 digest 鎖定：平常部署只需下載程式層；更新由 Dependabot 開 PR（.github/dependabot.yml）
FROM maven:3-eclipse-temurin-26-alpine@sha256:47da6465f015ac039849d9945219b9d08d6bc4d5afa2dea2aaee6be405155f97 AS build
WORKDIR /src
# 先只下載依賴（pom.xml 沒變時可沿用這一層的快取）
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src/ src/
RUN mvn -B -q -DskipTests package \
 && java -Djarmode=tools -jar target/api.jar extract --layers --launcher --destination /extracted

# alpine 版內建 busybox wget，healthcheck 用得到
FROM eclipse-temurin:25-jre-alpine@sha256:2ca9adf44f5c29d28ecd26cf92d75cc0c66b7f32bfd839a4439e363a8b428af8
WORKDIR /app
# 分層複製：依賴（約 22MB）很少變動，平常部署只需下載約 100KB 的應用程式層
COPY --from=build /extracted/dependencies/ ./
COPY --from=build /extracted/spring-boot-loader/ ./
COPY --from=build /extracted/snapshot-dependencies/ ./
COPY --from=build /extracted/application/ ./
# 不以 root 執行
RUN adduser -D -H -u 10001 app
USER app
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
# 限制記憶體（heap 最多 256MB、單執行緒 GC），避免 JVM 依主機記憶體自動放大
ENTRYPOINT ["java", "-XX:+UseSerialGC", "-Xmx256m", "-XX:+ExitOnOutOfMemoryError", \
            "org.springframework.boot.loader.launch.JarLauncher"]
