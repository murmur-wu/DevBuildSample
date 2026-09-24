# ADR 0007：image registry 從 GHCR 改為 Docker Hub

- 狀態：Accepted（取代 ADR 0001 中「推到 GHCR」的部分）
- 日期：2026-09-24

## 背景

部署時 buildserver 要從 registry 下載 image。在 buildserver 上實測：

| 測試 | 結果 |
|---|---|
| Cloudflare 測速（50MB） | 約 73MB/s |
| Docker Hub `python:3.13-slim`（約 45MB） | 7 秒（約 6MB/s 以上） |
| GHCR `linuxserver/nginx`（約 70–80MB） | 17 分鐘（約 70KB/s），較大的層會卡住很久 |
| GHCR 單一 blob，強制 IPv4、30 秒 | 約 35KB/s |
| GHCR 走 IPv6 | 主機沒有 IPv6 |
| MTU | 1500（正常） |

排除了 IPv6 與 MTU。換 DNS 也無效：GHCR 下載用的 `pkg-containers.githubusercontent.com` 是 anycast 位址，1.1.1.1、8.8.8.8 與原本的 DNS 給的都是同一組 IP。結論是網路業者到 GitHub CDN 的線路很慢，本專案無法修正。實際影響：Java 版第一次部署下載約 100MB 花了 15 分鐘，差點碰到 20 分鐘的上限；Node 版曾因基底 image 更新花了 9 分鐘。

## 決策

1. **image 改放 Docker Hub**（下載走 Cloudflare CDN，對 buildserver 很快）。
2. **六個後端共用一個 private repo** `murmur20260202/devbuildsample`，以 tag 區分：`<key>-<commit SHA>`（部署用）與 `<key>-latest`（手動操作用）。Docker Hub 免費方案（Personal）只有 1 個 private repo，公開 repo 則等於公開程式碼（GitHub repo 是 private），所以不用公開。
3. **認證**：repo secrets `DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`（Read & Write 的 personal access token）。build job 用它推 image；deploy job 在 runner 上 `docker login`、部署完 `docker logout`，主機上不必另外保存登入資訊。各 `cd-<key>.yml` 以 `secrets: inherit` 傳給 reusable workflow。
4. **仍保留 pull-based CD 的其他設計**：雲端 build、tag 含 SHA、回滾填舊 SHA、基底 image 以 digest 鎖定。

考慮過的替代方案：

- **繼續用 GHCR，部署前先從 Docker Hub 下載基底 image**：基底層可以跳過，但每次部署的程式層仍從 GHCR 下載（Go 執行檔約 11MB、.NET 程式數 MB），以 35KB/s 計算每次仍要好幾分鐘。
- **在 buildserver 上直接 build**：基底 image 與套件（npm、NuGet、Maven…）一樣要下載，還會失去「CI 驗證過的 image 就是部署的 image」與以 SHA 回滾的好處。
- **其他 registry**（Quay、GitLab、雲端廠商）：免費方案多半限公開或額度小，也要另外管理帳號；Docker Hub 已實測夠快。

## 後果

- 部署的下載時間從數分鐘到十幾分鐘，降到數秒到數十秒。
- 多了一組要管理的 token（有到期日，到期前要重新產生並更新 GitHub secret）。
- Docker Hub 的免費 private repo 被這個專案佔用；其他專案要放私有 image 時需共用此 repo 或升級方案。
- Docker Hub 有下載次數限制，但每次部署只下載 2 個 image（api 與 postgres），遠低於上限。
- 改用 Docker Hub 之前的 image 仍在 GHCR：回滾只能選改用之後的 commit；確認穩定後可到 GitHub 的 Packages 頁面刪除舊 image。
