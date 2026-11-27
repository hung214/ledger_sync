# 📒 LedgerSync — 本地優先跨平台記帳 App

> 一款**資料存在自己裝置、隱私為重**的記帳應用：連續快速記帳、台灣發票掃描（電子 QR＋紙本 OCR）、
> 信用卡預扣管理、預算與收入目標，並以 **Google Drive 帳號授權**做雲端備份與多裝置同步（無自建伺服器）。
>
> | | |
> |---|---|
> | 🌐 線上 PWA | **https://hung214.github.io/ledger_sync/**（免安裝、離線可用、加到主畫面像 App） |
> | 📄 介紹頁 | https://hung214.github.io/ledger_sync/landing/（功能總覽＋實機截圖） |
> | 支援平台 | **PWA（手機／桌面瀏覽器）** 為主要通道；另可建置 macOS / Android / iOS / Windows 原生版 |
> | 技術棧 | Flutter 3.47（單一程式碼庫）— 詳見 `specs/truth/techstack.md` |
> | 當前狀態 | **v0.5.1 已發佈**（M1~M7 全數完成；PWA 已上線；PWA 版戳 `0.5.1-pwa.20261127c`） |

---

## 1. 功能說明（已出貨）

### 1.1 快速記帳與連續記帳（FR-Q）
- **大金額計算機鍵盤**：聚焦金額欄由下滑入、失焦滑出；**OK／＝ 雙態按鈕**——輸入 `50×2` 時為「＝」（求值收合為 100）、純數字時為「OK」（存檔）；支援 `＋－×÷` 連算。
- **分類彈窗**：⭐ 常用類別（MRU 前 5）置頂＋兩層主/子類別展開＋「＋」即建即選。
- **智慧預設（Sticky）**：帳戶沿用上一筆、分類/商家依歷史帶入；金額每筆重設。
- **連續記帳**：儲存後彈出「繼續記下一筆？」——繼續（Sticky 保留）／復原上一筆／完成離開。
- 完全離線可用；桌面版 `Ctrl+N`（macOS `⌘N`）開關快記面板。

### 1.2 發票掃描記帳（FR-S）
- **電子發票雙 QR 解析**（財政部官方規格 v1.9）：左碼（發票資訊）＋右碼（明細）自動湊單，帶入發票號、日期、總額與明細。
- **紙本收據 OCR**：iOS/macOS 走 Apple Vision 本機辨識（其他平台回退手動輸入）。
- 辨識**全在本機**（離線可用、隱私不出裝置），結果一律經「**確認清單**」逐筆人工把關後入帳，原圖存為附件。
- 入口：快記頁右上角「掃描」（桌面：工具列／`Ctrl+Shift+S`／**匯入圖片**解 QR）。

### 1.3 信用卡預扣與帳單週期（FR-C）
- 刷卡**先記錄（預扣）**：立刻累計「本期應付」，銀行帳戶餘額不動；繳款顯示「信用卡繳款」流向標籤。
- 到結帳日自動彙總**帳單** → 繳款截止提醒 → 點「全額/部分繳款」從連結帳戶產生還款轉帳。
- **結帳日歸屬每卡可設定**（當天算本期/下期）；逾期帳單持續標示（v1 不計息）。

### 1.4 支出預算與收入目標（FR-B）
- 總預算＋分類預算（**主分類預算＝含其全部子分類加總**；週期起始日 1~28 可自訂）＋收入目標三型。
- 金額與起始日皆由**計算機鍵盤輸入**（聚焦滑入，不跳系統鍵盤）。
- 進度條＋每日可用額＋月底預測；80%/100%/超支**分級視覺警示**。
- **收入目標**：月目標額與達標率，總覽顯示「本月預計結餘 = 收入目標 − 總預算」。

### 1.5 雲端備份與多裝置同步（FR-Y）
- **帳號授權式同步**：登入 Google 帳號即可，**無需任何同步密碼**；未設定憑證時 UI 降級顯示（不崩）。
- 本地優先：離線記帳不中斷，上線自動補同步；三種觸發模式＋啟動必同步一次。
- 雲端僅存於 App 專屬隱藏資料夾；**每日自動本地備份，保留 7 份**。
- 跨平台遷移：備份檔匯出/匯入，四平台互通。

### 1.6 帳戶與交易類型（FR-A/FR-T）
- 帳戶類型：現金／銀行／信用卡／電子支付（票證卡）／其他。
- 支出、收入、轉帳（含儲值/提款語意）、信用卡還款、退款。

### 1.7 定期交易（FR-T5）
- 房租、訂閱等固定收支：到期**提醒**，進「待確認」清單確認才入帳（金額可先改）；可跳過單期或刪除排程；明細頁常駐待確認 badge。

### 1.8 報表與統計（FR-R）
- 總覽儀表板（本月收支＋預算橫幅）、**分類占比甜甜圈**（依主類別彙總、百分比圈外引線）、**月趨勢**（上限 12 個月、可為負）、**累計結餘卡**（≥2 個月資料時出現）；三卡可切換支出／收入／淨額。
- 明細：分日群組＋每日小計＋月份制＋搜尋（分類/帳戶/金額/備註）。

### 1.9 明細管理與資料安全（FR-T3/FR-X）
- 交易**編輯／拆分**（點明細列）；**最近刪除**：30 天內可還原，另提供永久刪除（二次確認）。
- **App 鎖（PIN）**＋背景逾時門檻＋總覽 👁 一鍵遮蔽金額；無廣告、無第三方追蹤器。
- 資料管理：可勾選範圍清空（雲端不清空、30 天內可還原）。

### 1.10 資料進出（FR-O5）
- **CSV 匯入**：分隔符自動偵測、欄位中英別名對應、金額千分位/負號/括號解析、重複資料冪等跳過。
- **CSV 匯出**＋**DB 備份/還原**（跨裝置）。

### 1.11 PWA 體驗
- **離線可用**（offline-first）＋**自動更新**（新版偵測→自動重載）；可「加到主畫面」全螢幕執行。
- 手機相機掃描（getUserMedia＋WASM 解碼）與桌面「匯入圖片」解 QR 皆支援。

---

## 2. 平台與部署

| 能力 | PWA（手機瀏覽器） | PWA（桌面瀏覽器） | macOS 原生 | iOS/Android/Windows 原生 |
|---|---|---|---|---|
| 記帳全功能 | ✅ | ✅ | ✅ | ✅ |
| 電子發票 QR（相機） | ✅ | ✅ 匯入圖片 | ✅ 匯入圖片 | ✅ |
| 紙本 OCR | — | — | ✅ Vision | —（規劃中） |
| Google Drive 同步 | ✅ | ✅ | ✅ | ✅ |
| 離線＋自動更新 | ✅ | ✅ | —（本地 App） | —（本地 App） |

> 🧪 **iOS 採用 PWA（PM 2026-11-16 決策 A）**——免付費上架、免審核；原生建置仍保留。

---

## 3. 快速開始

### 3.1 一般使用者（免安裝）
1. 手機或電腦瀏覽器開 **https://hung214.github.io/ledger_sync/**
2. 加到主畫面：iPhone Safari「分享 → 加到主畫面」；Android 選單「安裝應用程式」
3. 詳細圖文：`specs/plan/user-guide.md`

### 3.2 開發者環境
- Flutter SDK 3.47（stable）／Dart 3.13＋各平台工具鏈

```bash
flutter pub get
flutter run                      # 選擇裝置
flutter run -d macos             # macOS 原生
flutter run -d chrome            # PWA（開發）
```

### 3.3 測試（紅綠燈落點）
```bash
flutter test                     # unit＋widget（當前 298 全綠）
flutter analyze                  # 靜態分析（零警告 gate）
pwsh tool/sync_features.ps1      # 同步 BDD feature 檔（specs → 測試副本，禁止手改副本）
```
> ⏸️ **FE 整合測試暫停中**（PM 2026-10-24：`integration_test/features/*` 待指示再恢復；期間護欄＝`flutter test`＋`flutter analyze`）。

### 3.4 PWA 部署
```bash
flutter build web --release -t lib/main_web_app.dart --base-href=/ledger_sync/ \
  --pwa-strategy=offline-first --dart-define=APP_VERSION=0.5.1-pwa.<日期戳>
# ⚠️ 必須 -t lib/main_web_app.dart（PWA 入口）——漏掉會以 native 入口（dart:io）編出白畫面空殼
# 產物推 gh-pages 分支（orphan＋.nojekyll）→ 線上 CDN max-age=600
```

---

## 4. 操作方式（App 內主要流程）

### 4.1 第一次使用
1. 開啟 App → 引導頁（資料預設只存本機）。
2. 三選一：**開始使用**（新建帳本）／**從雲端還原**／**匯入備份檔**。
3. （可跳過）連結雲端：Google Drive 授權 → 立即首次備份。

### 4.2 快速記一筆
1. 點「＋」（桌面：`Ctrl+N` 或工具列鈕）。
2. 帳戶/分類/商家已智慧預填 → 點金額欄（計算機滑入）**輸入金額**（可用 `＋－×÷` 連算，按 **＝** 收合結果）。
3. 點「分類」開彈窗選類別 → 按 **OK** 儲存 → 「繼續記下一筆？」：**繼續**／**復原上一筆**／**完成**。

### 4.3 掃發票記帳
1. 快記頁右上角「**掃描**」（桌面：工具列／`Ctrl+Shift+S`／匯入圖片）。
2. 對準電子發票：左側 QR（資訊）＋右側 QR（明細）自動湊單；紙本走 OCR（iOS/macOS）。
3. 進「確認清單」逐筆檢查（金額/分類/帳戶可改）→ **OK** 入帳自動跳下一筆。

### 4.4 信用卡週期
1. **記錄**：快記選信用卡輸入金額 →「本期應付」立即累加。
2. **結帳**：結帳日自動彙總帳單並提醒。
3. **繳款**：全額／部分 → 從連結帳戶產生還款轉帳；逾期持續標示。

### 4.5 預算與收入目標
1. 預算頁「＋」→ 選類型（總預算/分類預算/收入目標）→ **金額與起始日都用計算機輸入**。
2. 記帳後進度即時更新；80%/100%/超支分級變色。

### 4.6 雲端同步
- 開啟 App 必同步一次；設定→雲端與同步可「立即同步」、查看狀態與衝突。
- 換裝置：新裝置登入同一帳號 →「從雲端還原」。

### 4.7 定期交易
1. 設定定期項目（金額、帳戶、週期）→ 到期提醒 → 待確認清單確認入帳／跳過／刪除。

### 4.8 安全
- 鎖定：設定→安全→App 鎖（PIN；背景逾時門檻可調）。
- 遮蔽：總覽頁 👁 一鍵遮蔽所有金額。

### 4.9 分類管理
1. 設定 → 分類管理 →「＋ 新增」：自訂名稱、圖示（子類別跟隨主類別）。
2. 支援一層子分類；內建分類可隱藏、不可刪除。

### 4.10 明細與最近刪除
1. 明細頁分日群組＋每日小計；點列＝**編輯**（金額用計算機）；支出可**拆分**。
2. 刪除 →「最近刪除」30 天內可還原；亦可永久刪除（二次確認）。

---

## 5. 專案結構

```
lib/
├── main.dart                # native 入口（iOS/Android/macOS/Windows）
├── main_web_app.dart        # ★ PWA 入口（建置必須 -t 指定此檔）
├── core/                    # Clock、版本等通用工具
├── domain/                  # 實體與領域服務
├── application/             # UseCase／Provider 編排（SaveTransaction、SyncCoordinator…）
├── data/
│   ├── sqlite/              # AppDatabase（sqlite3／web＝sqlite3.wasm＋IndexedDB）
│   └── ...                  # 匯入匯出、備份、同步 Bundle
├── platform/                # 平台抽象（cloud/drive、ocr、scan、file_saver…）
└── presentation/            # 畫面（overview／quick_entry／ledger／scan／budget／demo…）

web/                          # PWA 殼：index.html、manifest、service worker、
├── landing/                  # 介紹頁（已上線 /ledger_sync/landing/）
└── sqlite3.wasm              # Web 資料庫引擎

test/                         # unit＋widget（298 全綠）
integration_test/features/    # FE BDD feature 副本（暫停中，來源 specs/plan/tests/frontend/）
specs/
├── plan/                     # tasks、ui 雛型、tests（FE/BE+dsl）、acceptance、debug、pm-actions、user-guide
└── truth/                    # techstack／data-spec（schema 唯一依據）
session.md / session-archive*.md   # 交接快照（近兩日）／歷史封存
```

**分層依賴方向**：presentation → application → domain；data/platform 實作介面（依賴反轉）。

---

## 6. 文件地圖

| 類別 | 檔案 | 說明 |
|---|---|---|
| 需求 | `SPEC.md` | 功能需求（FR-A~O）、非功能（NFR）、驗收場景 |
| 設計 | `SDD.md` | 架構、資料模型、同步協議、安全設計 |
| 行為 | `BDD.md` | Gherkin 情境總集＋AC 追溯矩陣 |
| 驗收 | `specs/plan/features/acceptance/` | PM 驗收標準 |
| 測試 | `specs/plan/tests/` | 前後端 feature 檔＋步驟 DSL（dsl.md） |
| 任務 | `specs/plan/tasks.md` | 任務分解、版控規範、truth 對齊 |
| 除錯 | `specs/plan/debug.md` | DBG-NNN 追蹤表 |
| 使用者 | `specs/plan/user-guide.md` | 安裝／備份還原／匯入／FAQ（單一來源） |
| PM 入口 | `specs/plan/pm-actions.md` | 憑證、部署、發版、待決策清單 |
| 雛型 | `specs/plan/ui/` | UI HTML 雛型（附規格便利貼） |
| 事實 | `specs/truth/` | techstack／data-spec |
| 交接 | `session.md`（＋`session-archive*.md` 歷史封存） | 目前快照＋下一步＋近兩日歷程 |
| 變更 | `CHANGELOG.md` | 每次發行版標註本版修改 |

---

## 7. 開發規範速覽

| 主題 | 規則 | 詳見 |
|---|---|---|
| 分支（PM 2026-11-23 制） | **每項修改開新分支 → MR 到 `feature/ios-pwa`**；禁止直接在 feature/ios-pwa／main 修改＋推送 | session.md §1 原則⑧ |
| Commit | `type(scope): subject`；紅綠燈循環 ≥1 commit | tasks.md §0.1 |
| TDD | 🔴 失敗測試 → 🟢 最小實作 → 🔵 重構（不得動 truth） | tasks.md §1 |
| 文件同步 | 功能修正必同步 SPEC/SDD/BDD/dsl 相關檔案 | tasks.md §7 |
| truth | schema/API/棧變更**先改 truth 再改碼** | tasks.md §5 |
| 除錯 | `specs/plan/debug.md` 建 DBG-NNN 條目＋回歸情境 | tasks.md §4.3 |
| PWA 發佈 | `-t lib/main_web_app.dart` 建置 → 推 gh-pages（版戳 `0.5.1-pwa.YYYYMMDDx`） | pm-actions §223 |
| 交接 | 休息前更新 `session.md`（近兩日制）＋`session-archive*.md` | session.md |

---

## 8. 路線圖

| 里程碑 | 內容 | 狀態 |
|---|---|---|
| M0 | 規劃文件集＋專案骨架 | ✅ |
| M1 | 核心本地記帳（帳戶/分類/交易/快記） | ✅ |
| M2 | 預算收入目標＋報表＋桌面適配 | ✅ |
| M3 | 信用卡帳單引擎 | ✅ |
| M4 | 發票掃描（QR＋OCR） | ✅ |
| M5 | 雲端備份（Drive 帳號授權）＋備份檔遷移 | ✅ |
| M6 | 多裝置同步＋定期交易 | ✅ |
| M7 | 安全打磨＋四平台 | ✅ |
| — | **v0.5.0 / v0.5.1 發佈（2026-11-23）＋PWA 上線** | ✅ |
| — | **計算機鍵盤全面改版**（聚焦滑入＋OK／＝雙態＋預算表單計算機） | ✅ 2026-11-27 |
| 後續候選 | 生物辨識（local_auth）、SQLCipher 加密（TR-6）、多幣別、iCloud、系統推播、T45 PWA 黑畫面診斷、Big5 品名 | ☐ |

---

## 9. 隱私與安全承諾

- 資料**預設只存在裝置**；未連結雲端時 App 不出網。
- QR／OCR 全部本機運算；無廣告、無第三方追蹤器。
- 雲端同步以**你的 Google 帳號授權**為準；檔案存於 App 專屬隱藏資料夾。
- 誠實聲明：本地資料庫**尚未加密**（SQLCipher 列為後續項目 TR-6）；**生物辨識尚未接入**（現行 App 鎖＝PIN）。

### 商標與素材授權（版權聲明）

- 產品名稱「LedgerSync」為暫定代號（上架前待命名，SPEC §12-1）。
- 圖示：Flutter Material Icons（**Apache-2.0**）與 Unicode 標準表情符號；未使用需授權之字型或圖庫素材。
- App 圖示（各平台＋PWA）：**自製 SVG 草稿**（暫定「A 帳本同步」稿，來源 `specs/plan/ui/logo-drafts/`，授權＝本專案自有；草稿評估中，上架前 PM 定稿後更新本節）。
- Demo／測試劇例中的商家、卡片、帳戶名稱（陽光超商、晨光早餐店、示例卡、票證卡等）皆為**虛構**，與任何真實品牌或商標無關；正式版亦不使用第三方商標。
- 若未來引入圖示包／字型，將於本節登記其授權來源。

## 10. 問題回報

- 開發中缺陷：見 `specs/plan/debug.md` 追蹤表。
- 文件與程式碼不一致 → 視為 Blocker（以 `specs/truth/` 為準修復）。
