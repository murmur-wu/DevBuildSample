<?php

// 容器啟動時先建立資料表，成功後才啟動 FrankenPHP（見 docker/entrypoint.sh）。
// DB 可能比 api 晚就緒（例如主機重開機），失敗就重試，與 Node、.NET 版相同。

declare(strict_types=1);

require __DIR__ . '/../src/ItemInput.php';
require __DIR__ . '/../src/ItemStore.php';

for ($attempt = 1; ; $attempt++) {
    try {
        (new Api\ItemStore())->migrate();
        break;
    } catch (PDOException $e) {
        fwrite(STDERR, "migration failed (attempt {$attempt}): {$e->getMessage()}\n");
        sleep(min($attempt, 10));
    }
}
