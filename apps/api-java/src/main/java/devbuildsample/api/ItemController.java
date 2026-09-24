package devbuildsample.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import devbuildsample.api.ItemStore.Item;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * 與 Node、.NET、PHP、Python、Go 版相同的 API：/health、/、/items CRUD；欄位名稱、狀態碼、錯誤訊息一致，
 * 以便共用 scripts/smoke-test.sh 驗收。不用 Spring 的 @RequestBody 自動轉換，
 * 與其他版一樣自己讀 JSON、自己檢查（錯誤訊息才會一致）。
 */
@RestController
public class ItemController {

    static final int MAX_BODY_BYTES = 64 * 1024;

    private final ItemStore store;
    private final JsonMapper json;
    private final String version;

    public ItemController(ItemStore store, JsonMapper json, @Value("${APP_VERSION:dev}") String version) {
        this.store = store;
        this.json = json;
        this.version = version;
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    record Health(String status, String db, String version) {}

    record Info(String name, String version) {}

    @GetMapping("/health")
    ResponseEntity<Health> health() {
        try {
            store.ping();
        } catch (DataAccessException e) {
            return ResponseEntity.status(503).body(new Health("error", e.getMostSpecificCause().getMessage(), null));
        }
        return ResponseEntity.ok(new Health("ok", "ok", version));
    }

    @GetMapping("/")
    Info info() {
        return new Info("api-java", version);
    }

    // 與 Node 版一樣接受結尾的 /（例如 /items/、/items/1/）
    @GetMapping({"/items", "/items/"})
    List<Item> list() {
        return store.list();
    }

    @PostMapping({"/items", "/items/"})
    ResponseEntity<Item> create(HttpServletRequest req) {
        Item item = store.create(readItemInput(req));
        // getContextPath() 是 PathBaseFilter 設定的前綴（例如 /java），沒帶前綴時是空字串
        return ResponseEntity.status(201).header("Location", req.getContextPath() + "/items/" + item.id()).body(item);
    }

    @GetMapping({"/items/{id}", "/items/{id}/"})
    Item get(@PathVariable String id) {
        return store.get(requireId(id)).orElseThrow(ItemController::itemNotFound);
    }

    @PutMapping({"/items/{id}", "/items/{id}/"})
    Item update(@PathVariable String id, HttpServletRequest req) {
        int itemId = requireId(id);
        return store.update(itemId, readItemInput(req)).orElseThrow(ItemController::itemNotFound);
    }

    @DeleteMapping({"/items/{id}", "/items/{id}/"})
    ResponseEntity<Void> delete(@PathVariable String id) {
        if (!store.delete(requireId(id))) {
            throw itemNotFound();
        }
        return ResponseEntity.noContent().build();
    }

    private static HttpError itemNotFound() {
        return new HttpError(404, "item not found");
    }

    private static int requireId(String raw) {
        Integer id = ItemInput.parseId(raw);
        if (id == null) {
            throw itemNotFound();
        }
        return id;
    }

    private ItemInput readItemInput(HttpServletRequest req) {
        ItemInput.Parsed parsed = ItemInput.parse(readJson(req));
        if (parsed.error() != null) {
            throw new HttpError(400, parsed.error());
        }
        return parsed.input();
    }

    private JsonNode readJson(HttpServletRequest req) {
        String contentType = req.getContentType();
        if (contentType == null || !contentType.startsWith("application/json")) {
            throw new HttpError(415, "content-type must be application/json");
        }
        // 先看 Content-Length；沒有的話（chunked）邊讀邊算，超過就停
        if (req.getContentLengthLong() > MAX_BODY_BYTES) {
            throw new HttpError(413, "body too large");
        }
        byte[] body;
        try (InputStream in = req.getInputStream()) {
            body = in.readNBytes(MAX_BODY_BYTES + 1);
        } catch (IOException e) {
            throw new HttpError(400, "invalid JSON");
        }
        if (body.length > MAX_BODY_BYTES) {
            throw new HttpError(413, "body too large");
        }
        try {
            JsonNode node = json.readTree(body);
            if (node == null || node.isMissingNode()) {
                throw new HttpError(400, "invalid JSON"); // 空的 body
            }
            return node;
        } catch (JacksonException e) {
            throw new HttpError(400, "invalid JSON");
        }
    }
}
