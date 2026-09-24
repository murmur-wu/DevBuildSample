package devbuildsample.api;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Properties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Application {

    public static void main(String[] args) throws InterruptedException {
        migrate();
        SpringApplication.run(Application.class, args);
    }

    /**
     * 啟動 Spring 之前先建立資料表。DB 可能比 api 晚就緒（例如主機重開機），失敗就重試，與另外五版相同；
     * 成功前不會開始接受請求。放在 Spring 啟動之前，docker stop 的 SIGTERM 才能立刻結束程序
     * （Spring 啟動中收到 SIGTERM 時，關閉流程會等啟動完成）。
     */
    static void migrate() throws InterruptedException {
        String url = "jdbc:postgresql://%s:%s/%s".formatted(
                env("DB_HOST", "db"), env("DB_PORT", "5432"), env("POSTGRES_DB", "postgres"));
        Properties props = new Properties();
        props.setProperty("user", env("POSTGRES_USER", "postgres"));
        props.setProperty("password", env("POSTGRES_PASSWORD", ""));
        props.setProperty("connectTimeout", "2");
        for (int attempt = 1; ; attempt++) {
            try (Connection conn = DriverManager.getConnection(url, props)) {
                conn.createStatement().execute(ItemStore.SCHEMA);
                return;
            } catch (SQLException e) {
                System.err.println("migration failed (attempt " + attempt + "): " + e.getMessage());
                Thread.sleep(Math.min(attempt, 10) * 1000L);
            }
        }
    }

    private static String env(String key, String fallback) {
        String value = System.getenv(key);
        return value == null || value.isEmpty() ? fallback : value;
    }
}
