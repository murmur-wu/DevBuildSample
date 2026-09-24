package devbuildsample.api;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.web.filter.OncePerRequestFilter;

/** 請求紀錄與路徑前綴（PATH_BASE）的處理，在 Spring MVC 之前執行。 */
@Configuration
public class RequestFilters {

    /**
     * 請求紀錄：每個請求一行「方法 路徑 狀態碼 耗時」，例如 {@code POST /java/items 201 4ms}（格式與另外五版相同）。
     * 放在最外層，才拿得到含前綴的完整路徑與最終狀態碼。路徑不含 query string；成功的 /health 不記。
     */
    @Bean
    FilterRegistrationBean<OncePerRequestFilter> requestLogFilter(@Value("${PATH_BASE:}") String pathBase) {
        String base = trimSlash(pathBase);
        var filter = new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
                    throws ServletException, IOException {
                long start = System.nanoTime();
                String fullPath = req.getRequestURI();
                try {
                    chain.doFilter(req, res);
                } finally {
                    String path = matches(fullPath, base) ? fullPath.substring(base.length()) : fullPath;
                    if (!(res.getStatus() == 200 && path.equals("/health"))) {
                        long ms = (System.nanoTime() - start) / 1_000_000;
                        System.out.println(req.getMethod() + " " + fullPath + " " + res.getStatus() + " " + ms + "ms");
                    }
                }
            }
        };
        var reg = new FilterRegistrationBean<OncePerRequestFilter>(filter);
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE);
        return reg;
    }

    /**
     * 對外經 tunnel 時網址帶前綴（例如 /java），cloudflared 不會去掉。把前綴當成 context path，
     * Spring MVC 比對路由時就會去掉它；沒帶前綴的請求（本機、healthcheck）照常處理。
     * 與 ASP.NET Core 的 UsePathBase 行為相同（server.servlet.context-path 則會讓沒帶前綴的請求 404）。
     */
    @Bean
    FilterRegistrationBean<OncePerRequestFilter> pathBaseFilter(@Value("${PATH_BASE:}") String pathBase) {
        String base = trimSlash(pathBase);
        var filter = new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
                    throws ServletException, IOException {
                if (base.isEmpty() || !matches(req.getRequestURI(), base)) {
                    chain.doFilter(req, res);
                    return;
                }
                chain.doFilter(new HttpServletRequestWrapper(req) {
                    @Override
                    public String getContextPath() {
                        return base;
                    }

                    @Override
                    public String getRequestURI() {
                        // 只有前綴（例如 /java）時視為 /java/，才會對應到 GET /
                        String uri = super.getRequestURI();
                        return uri.equals(base) ? base + "/" : uri;
                    }
                }, res);
            }
        };
        var reg = new FilterRegistrationBean<OncePerRequestFilter>(filter);
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE + 1);
        return reg;
    }

    static boolean matches(String path, String base) {
        return !base.isEmpty() && (path.equals(base) || path.startsWith(base + "/"));
    }

    static String trimSlash(String value) {
        return value.replaceAll("/+$", "");
    }
}
