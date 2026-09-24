package devbuildsample.api;

/** 要回給用戶端的錯誤（狀態碼 + 訊息），由 ApiErrors 轉成 {"error": "..."}。 */
public class HttpError extends RuntimeException {

    private final int status;

    public HttpError(int status, String message) {
        super(message, null, false, false);
        this.status = status;
    }

    public int status() {
        return status;
    }
}
