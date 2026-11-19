# PM 行動清單（PM Actions）

| 項目 | 內容 |
|---|---|
| 用途 | 彙整**只有 PM（產品負責人）能處理**的外部服務申請、帳號開通、憑證提供與產品決策——開發端已備妥接線點，取得資訊即可接上 |
| 文件版本 | v0.5（2026-11-17；**PWA 路線定案後全面修訂**——移除 iOS 原生上架依賴、Google 憑證縮減為 2 組、新增 §12 PWA 現況與維運） |
| 關聯文件 | **`user-guide.md`（使用者步驟單一來源）**、`tasks.md` §6.0/§6.0b（排程）、`debug.md`（技術缺陷）、`session.md`（當前進度） |
| 對象 | PM；技術細節可轉交開發解惑 |

> **一句話總結（2026-11-17）**：**PWA 已上線**（`https://hung214.github.io/ledger_sync/`——朋友 iPhone 可直接安裝使用）；
> 本地功能完整（**189 測試綠**：快記/明細/統計/掃描/匯入/清空/檔案備份還原）。
> 現在等三件事：**①Google 憑證（解鎖雲端備份——§1/§14）②AndroMoney CSV（匯入實測 I1）③發版 0.5.0 親口確認**。

---

## 0. 現況總覽（各平台發佈與雲端備份）

| 平台 | 發佈方式 | 雲端備份 | 備註 |
|---|---|---|---|
| **iOS（朋友）** | **PWA**（已上線；user-guide §2.1） | GIS 已接線 → **憑證後即用** | 無原生 App（免付費限制） |
| **iOS 原生 IPA** | CI 自動產出（未簽章，不可直接安裝） | — | 維護零成本；未來付費即可 TestFlight |
| **macOS／Windows** | 檔案交付（新版含匯入/檔案備份還原） | 憑證後＋loopback 接線（半天） | 檔案備份還原**不需憑證**已可用 |
| **Android** | APK 直接安裝（已發佈） | 可選後續（google_sign_in 接線） | |

---

## 1. ⚠️ 最高優先：Google 憑證（解鎖「雲端備份」）——**PWA 路線只需 2 組**

**為什麼卡**：雲端備份要使用者授權 Google——App 的身分（OAuth Client ID）必須由您在
Google Cloud Console 建立。**一次性設定，之後不用維護**。

### 1.1 您要做的事

**詳細步驟＝`specs/plan/user-guide.md` §6.1（6 步，約 10 分鐘）**。要點：

| # | 動作 | 要點 |
|---|---|---|
| 1 | 建立/選擇 Google Cloud 專案 | 名稱隨意（如 `ledgersync`） |
| 2 | **啟用 Google Drive API** | 免費額度足夠，不需計費 |
| 3 | **OAuth 同意畫面**：外部＋**測試使用者加您與朋友的 Gmail** | ⚠ 測試模式（≤100 人）**免審核等待**——原「送審數週」僅開放生產才需要 |
| 4 | 建立 **網頁應用程式** Client ID（PWA 用）：JavaScript 來源＝`https://hung214.github.io`＋`http://localhost:8899` | 只要 Client ID（無 secret） |
| 5 | 建立 **桌面應用程式** Client ID（macOS/Windows loopback 用） | Client ID＋Secret |
| 6 | 交給開發：**Web Client ID／Desktop Client ID／Desktop Secret** | Secret 勿入 git（§7） |

> ~~Android／iOS 原生 OAuth Client~~：**PWA 路線不需要**（原 §1.1 的 ×3 縮減為 2 組）；
> Android 雲端同步屬後續可選（屆時再加 Android client）。

### 1.2 開發端現況（2026-11-17）

| 項目 | 狀態 |
|---|---|
| `GoogleDriveAdapter`（appDataFolder 路徑映射/覆寫冪等/清單語意） | ✅ 完成＋測試綠 |
| **`GoogleApisDriveApi`（Drive REST v3 純 http 直呼；resumable 上傳）** | ✅ 完成＋**6 seam 測試**（P5；不引 googleapis 套件） |
| **Web OAuth（GIS `GisBearerClient`）＋ main_web_app 接線** | ✅ 完成——**等 client id 建置即用** |
| **macOS/Windows loopback OAuth 接線** | ⏳ 憑證到位後補上（約半天） |
| 本機檔案備份/還原（**不需憑證**） | ✅ 完成（資料管理→備份與還原） |
| 憑證未設定時 UI | ✅ 優雅降級（顯示未設定，不崩；本地功能不受影響） |

### 1.3 您**不需要**做的事

- ❌ 不需要付費／GCP 計費帳號（Drive API 免費額度足夠）
- ❌ 不需要自架伺服器（App 直連 Google；PWA＝免費靜態託管）
- ❌ 測試模式（≤100 測試使用者）**不需要 Google 審核**——加 email 即可

### 1.4 連網權限（開發端已備）

| 平台 | 設定 | 狀態 |
|---|---|---|
| macOS | 沙箱 `network.client`＋`network.server`（loopback） | ✅ entitlements 已加 |
| Android | release `INTERNET` 權限 | ✅ 已加 |
| iOS PWA／Windows | 瀏覽器/系統預設可連外 | ✅ |

---

## 2. 商店與簽章——**PWA 決策後大幅縮減（多為可選）**

| # | 項目 | 費用 | 現況 |
|---|---|---|---|
| 1 | **Apple Developer Program** | US$99/年 | **不需要**（iOS 走 PWA）；未來要原生 iOS/TestFlight 才申請 |
| 2 | **Google Play Console** | US$25 一次性 | **可選**（現行 APK 直接安裝已可用；要商店上架才需要） |
| 3 | **Android release keystore** | 免費 | 維持 APK 直接安裝→不需要；上架才需要（屆時我可代產） |
| 4 | macOS notarization | — | 檔案交付模式＝右鍵開啟即可（user-guide §2.2）；上架才需要 |

> CI 已自動產出四平台未簽名產物（tag 觸發）——**IPA/APK/DMG/exe 隨時都有**，等簽章或交付。

---

## 3. 商業化（可選；需您決策後才動工）

`commercialization.md` §2 已列四種付費模式。若要變現，需您先決定模式；若選「訂閱制」，還需加開：

| 項目 | 用途 | 備註 |
|---|---|---|
| App Store 內購／Google Play 訂閱 | 兩商店訂閱 | 分開設定（**需 §2 的帳號**） |
| RevenueCat 帳號（可選） | 統一管理跨平台訂閱 | 月交易額 $2.5k 內免費 |

> 若暫不變現，可先略過——不影響現有功能。
>
> **2026-11-17 金流可行性分析（PM 問綠界/藍新/PayPal 後留檔）**：綠界/藍新標準整合需要
> ①HashKey/IV 放進 App＝**人人可見可偽造** ②付款結果 webhook 要打到**伺服器**——
> 純客戶端（PWA/APK 直裝）**做不安全**。三條務實路徑：
> **A. 收款連結**（後台產連結→App「贊助」開連結→手動對帳；零開發）／
> **B. 授權碼解鎖**（Ed25519 離線驗簽＋產碼工具；零後端、偽造不了；約 1 天）／
> **C. Serverless 自動化**（Cloudflare Worker 收 webhook→自動寄碼；之後）。
> 門口：綠界（~1–2%，超商/ATM 強）／藍新（~2%）／PayPal（~3.4%，海外）。
> ⚠ 平台規則：PWA/Android 直裝可用這些金流；**上架商店後數位功能強制 IAP/Play 計費**。
> **PM 決策 2026-11-17：先不接金流**（恢復時從 B 起步）。

---

## 4. 待您決策的產品事項

| # | 決策 | 背景 | 影響 |
|---|---|---|---|
| 1 | **首次啟動引導頁（新建/還原/匯入）** | 現況首啟自動播種直接進主畫面 | PWA 朋友入場量大增後價值上升（可引導「還原備份檔/匯入 CSV」） |
| 2 | **NFR-03 定義** | `research.md` 提到但無定義 | 效能複測少一項 |
| 3 | **acceptance F03 測資字串修正（76→77 碼）** | 對齊欄位對照表與 T-H6 金測 | 需您複核後關閉 |
| 4 | **深色模式走查** | token 已覆蓋 | 下一版截圖走查（PWA＋桌面） |
| 5 | 多幣別 900／`notify_enabled=off` 語意 | M2 遺留 | 小範圍 |

---

## 5. 驗收走查（需您／QA 簽核）

| 項目 | 說明 |
|---|---|
| **PWA（iOS Safari）** | user-guide §2.1 安裝 → §3 記一筆 → §4 備份/還原 → §7 常見問題（**您手邊就能測**） |
| **macOS 新版** | 資料管理三卡（備份與還原／從其他 App 匯入／清空資料）＋匯入實測 |
| acceptance F09（清空）／**F12（匯入，新）** | 走查後簽核（F12 情境表見 acceptance 檔） |
| F03（發票掃描） | 桌面（檔案匯入）已可走查；行動相機＝SP-2b 後續 |
| AndroMoney 真檔匯入 | **等 I1 CSV**（§8 順序 3） |

---

## 6. 需要您提供的資訊彙總（PWA 路線精簡版）

| # | 資訊 | 用途 | 從哪取得 |
|---|---|---|---|
| 1 | **Web OAuth Client ID** | PWA 雲端備份（GIS） | user-guide §6.1 步驟 4 |
| 2 | **Desktop OAuth Client ID＋Secret** | macOS/Windows 雲端備份 | 同上步驟 5 |
| 3 | **AndroMoney CSV** | 匯入實測（I1） | AndroMoney 匯出（user-guide §5.1） |
| — | ~~Android/iOS OAuth Client~~ | PWA 路線不需要 | — |
| — | ~~Apple Team ID／簽章憑證~~ | PWA 路線不需要（未來原生才要） | — |
| — | ~~隱私權政策 URL~~ | 測試模式不需要；開放生產才要 | — |
| — | 商店 listing | 上架才需要（可選） | — |

---

## 7. 憑證注入方式（技術；您只需知道「不要進 git」）

- **PWA（Web）**：`flutter build web --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID=<id> …`（我執行）
- **桌面**：`--dart-define=GOOGLE_OAUTH_CLIENT_ID=<id> --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=<secret>`（我執行）
- **CI（GitHub Actions）**：存為 GitHub Secrets 注入（正式發佈時設定）。
- **絕對不要** commit 到 git；若外洩，於 Console 撤銷重產。
- 未設定時 App **不會崩**：顯示「雲端功能未設定」，本地功能（含**檔案備份還原**）完全可用。

---

## 8. 建議執行順序（PM 視角；2026-11-17 更新）

1. **今天（10 分鐘）**：§1.1／user-guide §6.1 的 Google 憑證 6 步 → 交 3 個值。
2. **我接手**：①PWA 帶 Web Client ID 重新部署（雲端備份即用）②macOS/Windows loopback 接線＋交付新版。
3. **實測**：您用 AndroMoney 真檔走匯入（I1→I2）；朋友安裝 PWA（user-guide §2.1）。
4. **發版 0.5.0**：您親口確認 → push tag（CI 四平台＋CHANGELOG 自動帶入）。
5. **之後（可選）**：Android 雲端同步接線／商店上架（§2）／引導頁（§4#1）。

---

## 9. 2026-10-22 分類體系決策記錄（已實作）

| 決策 | 內容 | 狀態 |
|---|---|---|
| **主類別集定稿** | 支出 14：餐飲食品/服飾美容/居家生活/交通運輸/教育學習/休閒娛樂/3C通訊/圖書刊物/汽機車/醫療保健/人情交際/理財投資/其他/費用；收入 2：一般收入/投資收入 | ✅ 已播種＋truth 更新 |
| 轉帳 | 為交易類型（快記已支援支出/收入/轉帳模式），不需分類列 | ✅ 無需變更 |
| 主/子分類頁 | 階層結構：主類別群組（可折疊）＋子分類縮排＋拖曳排序 | ✅ 已實作 |
| 常用類別區 | 快記分類選擇器最上方常駐「常用」：最近使用前 10 個 | ✅ 已實作 |
| **子分類預設清單** | 播種 61 項（16 主類別全配）；可在分類管理自行調整（存進使用者資料） | ✅ 已播種 |
| **既有裝置** | 分類集變更僅影響全新安裝；舊裝置用 資料管理→清空資料 後重啟重播種 | ⚠️ 需您操作一次 |

---

## 10. 發佈流程（PM 2026-10-23 制定；持續有效）

> **規則：任何版本發佈（push tag）之前，必須先讓 PM 在本地預覽並親口確認。**
>
> **2026-10-26：每次發行版都必須標註本次修改**——發版前於 `CHANGELOG.md` 新增該版區段，
> 發佈流水線自動寫進 GitHub Release 說明；**未填不得發版**。
>
> **2026-10-29 PM 簽核（桌面掃描）**：檔案匯入＋圖片 QR 解碼（file_selector＋zxing2；techstack v0.3.8）。

| 預覽形式 | 適用 | 說明 |
|---|---|---|
| **雛型 HTML**（`specs/plan/ui/*.html`） | 版面/流程定稿 | 改版必同步更新雛型（truth） |
| **UI_DEMO 畫廊**（App 內） | 元件風格 | ✅ 可用（Xcode 已恢復） |
| **實機安裝**（macOS 新版／**PWA 網址**／Android APK） | 真機走查 | PWA＝重新整理兩次抓新版（user-guide §2.4） |

---

## 11. 本機建置／實機驗證前置（2026-10-23）——✅ 已解決（授權已同意；Xcode 已恢復）

> 歷史根因：Xcode 升級（26.6→27.1）後要求重新同意授權 → `xcrun` 被鎖 → git/flutter/cocoapods 全鎖。
> **2026-10-24 已 `sudo xcodebuild -license accept` 解鎖**——以下保留供未來升級 Xcode 時參考。

### 若未來升級 Xcode 後再次出現 license 鎖（一行解鎖）

```bash
sudo xcodebuild -license accept
```

### macOS「隱私權與安全性」常見允許項（首次執行時）

| 項目 | 怎麼允許 |
|---|---|
| Gatekeeper 未簽章 App | 右鍵 → 打開（或系統設定→隱私權與安全性→「仍要打開」） |
| 通知（預算警示） | 允許「LedgerSync」 |
| 本機網路 | 允許 |

### 環境備註

- CocoaPods `ffi` 警告 → `gem pristine ffi --version 1.17.2`；再不行 `brew reinstall cocoapods`。
- 磁碟：建置需 2~4 GiB；不足先清 `~/Library/Developer/Xcode/DerivedData`。
- **PWA 建置指令**（開發備忘）：`flutter build web --release -t lib/main_web_app.dart --base-href=/ledger_sync/ --pwa-strategy=offline-first` → 推 `gh-pages`。

---

## 12. PWA 現況與維運（原 §12 決策＋§15 部署合併；2026-11-17）

| 項目 | 現況 |
|---|---|
| 決策 | **A（採用 PWA）**（PM 2026-11-16；iOS 免付費發佈） |
| 網址 | **`https://hung214.github.io/ledger_sync/`**（已上線；離線可啟動） |
| 技術 | sqlite3.wasm＋IndexedDB（遷移 v1→v6 同套）；附件 IndexedDB；GIS 雲端（等憑證）；**189 測試綠＋headless 雙視窗 0 異常** |
| 部署流程 | `flutter build web -t lib/main_web_app.dart --base-href=/ledger_sync/ --pwa-strategy=offline-first` → 推 `gh-pages`（orphan＋.nojekyll） |
| 更新方式 | 使用者重新整理兩次（user-guide §2.4） |
| OAuth origin | 正式 `https://hung214.github.io`＋開發 `http://localhost:8899`（§14 步驟 4 登記） |
| **資料安全提醒** | 刪除 PWA 圖示／清瀏覽器網站資料＝**本地資料消失** → user-guide §4（備份到檔案/雲端備份） |
| IPA 並存 | CI 產出未簽章 IPA——**維護零成本**；未來付費 Apple Developer 即可 TestFlight（§2） |
| 使用者文件 | **`user-guide.md`（單一來源：安裝/備份/匯入/FAQ）** |

---

## 13. GitHub 推送憑證——✅ 已解決（2026-11-16）：改用 SSH

`git@github.com:hung214/ledger_sync.git`（公鑰已註冊；原 HTTPS token 過期問題結案）。

---

## 14. Google 憑證（2026-11-17）——**步驟單一來源＝`user-guide.md` §6.1**

您要做的＝6 步（建專案→啟用 Drive API→同意畫面+測試使用者→網頁應用程式憑證→
桌面應用程式憑證→交 **Web Client ID／Desktop Client ID／Desktop Secret**）。
憑證到位後：**PWA 重新部署即用**（接線已完成）；macOS/Windows 補 loopback 接線（約半天）。

---

## 15. GitHub Pages——✅ 已完成（2026-11-16 PM 開啟；2026-11-17 最新版）

內容併入 **§12 PWA 現況與維運**（網址/部署/更新/資料安全）。


## §16 未完成功能清單（PM 2026-11-19 要求列管；勾選＝已完成）

### M2（付費/成長前必須）
- [ ] **本機推播通知**：flutter_local_notifications 接線（繳款提醒 N-5／預算警示 N-1～3／定期到期 N-6——目前僅 App 內 SnackBar）
- [ ] **標籤系統**（UI 已預留欄位；資料模型未建）
- [ ] **多幣別匯入**（非 TWD 目前自動略過；語意待定：金額幣別欄＋匯率）

### M4（掃描/相機尾段）
- [ ] **手機原生即時相機掃描**（Android/iOS mobile_scanner 接線——目前手機掃描頁為佔位；可用替代＝PWA 相機／檔案匯入）
- [ ] **桌面即時相機掃描**（macOS/Windows——目前桌面＝「掃描／匯入圖片」檔案路徑）

### 等 PM 提供/決策
- [ ] **Google 憑證**（Web/Desktop Client ID——給了半天內接完雲端備份/同步）
- [ ] **AndroMoney CSV 實檔**（I1 匯出→I2 對映確認→F12 驗收；引擎別名已就緒）
- [ ] **發版 0.5.0 親口確認**（→ 合併 main＋tag＋CI 四平台＋PWA 部署）
- [ ] 金流（已決策不接；恢復時從授權碼解鎖起步，pm-actions §3）
- [ ] TestFlight/商店（付費 $99 決策後）
