# 開發任務分解（Tasks — 分割擊破）

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.3（初版） |
| 定位 | 把 SPEC/SDD/BDD/acceptance/tests/truth 轉成**可執行的開發任務清單**：每個任務小到一個人一次紅綠燈循環可完成 |
| 輸入 | `research.md` §2（Sprint 計畫）、`specs/plan/tests/`（FE/BE feature 檔 + dsl.md）、`specs/truth/*` |
| 任務狀態標記 | ☐ 未開始 → 🔴 紅燈（測試已寫、失敗中）→ 🟢 綠燈（測試通過）→ 🔵 藍燈（重構中）→ ✅ 完成（對齊 truth 已驗證） |

---

## 0. 版控 / 檔名 / 格式規範

### 0.1 版本控制（Git）
| 規範 | 內容 |
|---|---|
| 分支 | trunk-based：`main` 永遠可發佈；**每個功能一條分支**：`feature/F{nn}-{slug}`（例：`feature/F04-credit-card-billing`，自 main 切出，完成後 merge 回 main）；S0 Helper 用 `feature/T-H-test-helpers`；修復分支 `fix/{issue}-{簡述}` |
| Commit | `type(scope): subject`，type ∈ feat/fix/test/refactor/docs/chore；scope 用 FR 或模組（例：`feat(FR-C2): billing boundary rule include/exclude`）。**粒度：每個情境紅綠燈循環至少一個 commit**（🔴 `test(dsl): F04-BE 結帳歸屬紅燈` → 🟢 `feat(FR-C2): …` → 🔵 `refactor: …`）；每個功能合併前至少含 T-Fxx-BE 與 T-Fxx-FE 各一個功能級 commit |
| PR | 標題必帶 FR/AC/情境 ID（追溯鍵）；描述需附：紅燈證據（失敗輸出）→ 綠燈證據（通過輸出）→ truth 對齊檢查清單（§5） |
| 合併 | P0 測試全綠才可合併；功能分支以 `--no-ff` merge 回 main（merge commit 帶 FR/AC，例：`Merge feature/F04-credit-card-billing (FR-C, AC-04/11)`），合併後刪除功能分支；truth 檔（specs/truth/*）變更須另外一個 PR 且由架構簽核（research §1.3 護欄） |
| Tag | **工作完整併至 main 時自動建立版本標籤並發佈**：tag-on-main workflow 讀 pubspec `version`（去 +build）→ `v{major.minor.patch}` 標籤（已存在則略過）→ 檢查 Release 是否已發佈（冪等）→ 缺則**同一工作流**建置 Android/Windows/macOS/iOS 並發佈 GitHub Release（⚠ 2026-10-19 修正：GITHUB_TOKEN 推標籤不觸發下游工作流——原鏈式設計從未生效，v0.1.0~v0.4.0 皆無 Release；`release.yml` 保留為手動推標籤之後備）。P0 把關由同 push 之 CI（analyze＋test）負責 |
| Session | 休息／中斷前：更新根目錄 `session.md`（快照＋下一步＋歷程）、回寫 `tasks.md` §6 狀態、確認已 commit；恢復工作依 `session.md` §4 SOP |
| 禁止 | force push main；跳過測試（--no-verify）合併；truth 與程式碼同 PR（先 truth 後碼） |

### 0.2 檔名格式
| 對象 | 規範 | 例 |
|---|---|---|
| Dart 原始碼/測試 | snake_case | `billing_cycle_service.dart`、`op_bundle_applier_test.dart` |
| Feature 檔 | `F{nn}_{slug}.feature`，與 `specs/plan/tests/{frontend,backend}/` **同名同步** | `F04_credit-card-billing.feature` |
| UI 雛型 | `NN-{名稱}.html` | `05-scan-review.html` |
| truth 檔 | **固定名稱不得改名**：`techstack.md` / `api-spec.yaml` / `data-spec.dbml` | — |
| 文件 | SPEC.md / SDD.md / BDD.md 為根目錄固定檔；規劃類放 `specs/plan/` | — |

### 0.3 內容格式
- Feature 檔：Gherkin 英文關鍵字＋繁中敘述、2 空格縮進（dsl.md §1）。
- Dart：`dart format` 為 CI gate；分析零警告（research §2.4）。
- 文件改動必帶版本號與修訂記錄（文件集以 v0.3 對應）。

---

## 1. 測試驅動開發：紅燈 → 綠燈 → 藍燈

每個情境（Scenario）都走一次三燈循環；**任務的最小單位 = 一個情境的一次循環**。

| 燈 | 動作 | 完成條件 | 禁止 |
|---|---|---|---|
| 🔴 **紅燈** | 從 `tests/{backend\|frontend}/Fxx.feature` 選一個情境 → 依 dsl.md 實作 step definitions → 執行**確認失敗**（因功能未實作） | 失敗原因 = 「功能不存在」，不是語法錯誤 | 先寫實作再補測試；跳過紅燈直接寫碼 |
| 🟢 **綠燈** | **最小實作**讓該情境通過（只求正確，不求優雅） | 該情境綠燈；同檔其他情境未被破壞 | 過度設計；為了綠燈改測試斷言 |
| 🔵 **藍燈** | 測試全綠後**重構**：命名、抽共用 helper、消除重複 | 綠燈保持；程式碼更簡潔 | 改變 truth（schema/API/stack）——若重構發現需要動 schema/API：**停止**，走 §3 truth 變更流程後回到紅燈 |

**循環外的紅燈（truth 驅動）**：若 schema/套件/API 變更需求先出現（例如 F04 需要新表），順序為：改 `data-spec.dbml`（PR）→ 寫 migration 與 schema 回歸測試（紅燈：舊 DB 無新表）→ migration 綠燈 → 才開始 feature 情境循環。

**對齊驗證**：每個 🔵 結束跑 `truth 對齊測試`（T-H9），確保碼與 truth 無落差（落差 = Blocker）。

---

## 2. 共用測試模組 HELPER（T-H，先於所有 Feature 開發）

> 位置：`test/helpers/`（BE）與 `integration_test/helpers/`（FE）；每個 Helper 自身也走紅綠燈（先寫使用範例測試）。

| 任務 ID | Helper | 內容 | 對應 dsl.md 掛鉤 | 狀態 |
|---|---|---|---|---|
| T-H1 | 記憶體 DB fixture | drift in-memory（測試關 SQLCipher）、每 Scenario 重建、seed API | BE Given「已重置記憶體資料庫」 | ✅（sqlite3 直連——TR-7；9622009/b557029） |
| T-H2 | Fake clock | 凍結/快轉時間（結帳日、預算週期、逾期、30 天還原） | 「模擬系統時間為 {dt}」 | ✅ |
| T-H3 | In-memory CloudStorageAdapter | list/upload/download/delete 假實作，可控成功/失敗/延遲/斷線 | BE「模擬雲端…」、FE @sync | ✅（雙裝置拓撲） |
| T-H4 | Notification spy | 攔截通知、斷言編號/內容/次數（N-1~N-10） | 「通知 spy 收到 N-{n} 恰 {k} 次」 | ✅ |
| T-H5 | 測試資料集 Builder | acceptance 前置條件一鍵建立（帳戶/分類/交易/預算/卡/定期） | 所有 Given 資料步驟 | ✅（DbFixture） |
| T-H6 | 發票測資 fixtures | 77 碼左 QR 字串、右 QR deflate+Base32 產生器、OCR 文字/圖片 fixtures | F03 BE/FE | ✅（InvoiceQrFixtures＋OcrReceiptFixtures） |
| T-H7 | Gherkin Runner | BE：自製 runner 掛 flutter_test；FE：flutter_gherkin 設定（tag 過濾） | — | ✅（自製 runner——TR-9） |
| T-H8 | FE 掛鉤 | lifecycle 模擬（背景秒數）、鍵盤/快捷鍵注入、截圖報告 | FE「App 切至背景」「Ctrl+N」 | 🟢（pressShortcut 落地 F03-FE；pumpBackground F08 啟用） |
| T-H9 | **truth 對齊測試** | ①schema snapshot ↔ `data-spec.dbml` 解析比對 ②pubspec 依賴版本 ↔ `techstack.md` §2；落差即紅燈 | §5 對齊清單的自動化 | ✅（CI＋本地；v1~v5 全覆蓋） |

---

## 3. 資料庫版本控制（Drift Migration）

### 3.1 規則
1. **單一事實來源**：schema = `specs/truth/data-spec.dbml`；drift schema 版本號 = dbml 變更序號。
2. 變更流程：改 dbml（獨立 PR）→ 產生 migration step → **schema 回歸測試**（紅燈：舊版 DB 升級後缺新表/資料遺失）→ 綠燈 → 更新 SDD §4.2 摘要。
3. 禁止：直接改 drift 表而不改 dbml；刪欄/改型不寫遷移；跳版本升級。
4. 每版必附「降級防護」：升級前自動保護備份（FR-Y10 語意）。

### 3.2 Schema 版本歷程（綁里程碑）

| 版本 | 里程碑 | 新增表 | 對應任務 |
|---|---|---|---|
| v1 | M1 | accounts、categories、transactions、oplog、settings、templates | T-S1 |
| v2 | M2 | budgets、income_goals、transactions_fts（FTS5 bigram 影子表，SP-1） | T-S2 |
| v3 | M3 | credit_card_details、statements、statement_items、refund_links、installment_plans | T-S3 |
| v4 | M4 | attachments（+ blobs 目錄約定） | T-S4 |
| v5 | M5/M6 | sync_events（**隨 F07/M5 提前落地**——衝突事件）＋recurring_transactions（表一次到位；業務使用屬 M6） | T-S5 |
| v6 | M8 | accounts.include_in_totals（FR-A2/A6/A7 合併計算） | T-S6 |

> 註：credit_card_details 的 boundary_rule、statements 的 overdue_notified 等欄位隨 v3 一次到位（避免中途改欄）。

| 任務 ID | 環節 | 內容 | 狀態 |
|---|---|---|---|
| T-S1 | M1 migration | v1 建表 + schema 回歸測試（v0 空 DB → v1）＋ truth 對齊（T-H9 基線） | ✅ |
| T-S2 | M2 migration | v2 預算/FTS5 + bigram 寫入觸發器/服務邏輯 + 回歸測試（v1→v2 資料保留） | ✅ |
| T-S3 | M3 migration | v3 信用卡/帳單 + 回歸測試（既有交易 settlement_status 預設 none） | ✅ |
| T-S4 | M4 migration | v4 attachments + 回歸測試 | ✅ |
| T-S5 | M5/M6 migration | v5 sync_events（F07 衝突事件，M5 已落地）＋recurring_transactions（M6 使用）＋回歸測試（已落地：直達 v5／v4 升級／冪等） | 🔵（表與遷移已完成；recurring 業務屬 M6） |
| **T-S6** | **M8 migration** | **v6 `accounts.include_in_totals`（FR-A2/A6/A7 合併計算）**＋回歸測試（直達 v6／v5 升級資料保留／冪等）＋T-H9 對齊（data-spec v0.3.3） | ☐ **待開工** |

---

## 4. Feature 依序開發（每個 feature 檔：BE → FE → 對齊）

### 4.0 標準作業順序（每個 Fxx 相同）
0. **開分支**：自 main 切出 `feature/F{nn}-{slug}`（一個功能一條分支，見 §0.1）。
1. **讀**：`acceptance/Fxx` ＋ `tests/frontend|backend/Fxx.feature` ＋ truth 相關段落（data-spec 對應表、techstack 套件）。
2. **BE 紅綠燈**：後端情境逐條 🔴→🟢→🔵（P0 先於 P1），每情境 ≥1 commit。
3. **FE 紅綠燈**：前端情境逐條（以 BE 為掛鉤，不重驗計算），每情境 ≥1 commit。
4. **對齊**：跑 T-H9 truth 對齊測試 + CI 全綠。
5. **PR／合併**：標題帶 FR/AC；附紅/綠證據；`--no-ff` merge 回 main；acceptance 手動情境（無法自動化部分）留給 QA 走查簽核。
6. **收尾**：`tasks.md` §6 該功能狀態改 ✅；休息或中斷前更新 `session.md`。

### 4.1 任務總表

| Feature | BE 任務（情境數） | FE 任務（情境數） | truth 對齊項 | 里程碑 | 狀態 |
|---|---|---|---|---|---|
| F01 快記 | T-F01-BE（8：智慧預設規則×4、儲存事務、Undo、離線、效能）——**8/8 ✅**（QuickEntryPreset／SaveTransactionUseCase 事務＋oplog 同 transaction／UndoLastTransactionUseCase 墓標／S7 離線／NFR-01 效能 P95 0ms） | T-F01-FE（7：預填呈現、對話框、Sticky、完成、時間選擇器、復原、桌面快捷鍵）——**🟢 macOS 全綠**（預填／對話框／Sticky／完成／時間選擇器／復原＋桌面 ⌘N 快捷鍵 F01-S1.11） | settings key 命名（settings 表）✅ | M1 | ✅（併入 main；FE 逐檔回歸持續綠） |
| F02 交易帳戶 | T-F02-BE（6：金額驗證、轉帳守恆、儲值語意、軟刪除、還款、多幣別）——**6/6 ✅**（多幣別照數學修：餘額 −2,200；fxRate 換算入 BalanceCalculator） | T-F02-FE（6：禁用態、轉帳樣式、儲值文案、最近刪除、拆分＋**S2.9 計算機鍵盤**）——**6/6 ✅**（executeSplit 總額守恆＋TxTile 拆分樣式） | tx_kind/settlement_status enum（✅ schema v1 覆蓋）；fx_rate（✅ TxRow/Tx/BalanceCalculator 換算） | M1/M2 | ✅ |
| F03 掃描 | T-F03-BE（7：QR 解析、明細合併、回退、OCR 信賴度、附件定址、離線、效能）——**🟢 7/7**（InvoiceQrParser 切片解析＋ReceiptFieldExtractor heuristics＋AttachmentStore 內容定址；techstack v0.3.7 image＋crypto PM 簽核；測資 77 碼規格修正） | T-F03-FE（6：入口、權限、確認清單、高亮、連拍、桌面匯入）——**🟢 6/6 macOS 實跑**（scan-entry 雙入口＋ScanPage 狀態機（權限閘/計數/縮圖）＋ReviewPage（總額人工檢視＋高亮擋下＋逐張跳）＋ImportPage＋⌘⇧S 快捷鍵＋📷 附件標記；pressShortcut T-H8 落地） | attachments.sha256（blobs 約定）✅ schema v4；測資 fixture=T-H6 | M4 | ✅（**M4 完成併入 main 69fd736；v0.4.8 已 tag**：FE 回歸 6/6＋部署驗證通過（Release 47.6MB＋二次啟動）；行動相機 mobile_scanner 接線屬 acceptance 走查前補——SP-2b） |
| F04 信用卡 | T-F04-BE（10：預扣、補算、歸屬 outline、clamp、繳款×2、提醒、逾期、分期、退款、生效日）——**🟢 12 情境執行全綠**（5 服務：BillingCycle/RepayStatement/NotificationCheck/Installment/Refund＋生效日） | T-F04-FE（5：帳單呈現、繳款流程、部分繳、設定顯示、逾期標示）——**🟢 macOS 全綠**（CreditCardPage＋CardSettingsPage＋總覽入口） | **schema v3**（T-S3 ✅）；boundary_rule enum | M3 | ✅（**M3 完成併入 main c1b52b0；v0.4.7 已 tag**：FE 回歸 4/4＋部署驗證通過（Release 47.4MB＋二次啟動）） |
| F05 預算 | T-F05-BE（5：閾值×2、含預扣、達標率、起始日）——**5/5 ✅**（BudgetAlertService 冪等 sync 點＋notif_state 去重） | T-F05-FE（5：警示色、超支、預扣標籤、達成、通知開關）——**5/5 ✅**（預算分頁＋總覽卡；FE 基線自洽修正 S1 7000/S2 8320） | **schema v2**（T-S2 ✅）；budgets/income_goals | M2 | ✅ |
| F06 定期交易 | T-F06-BE（5：到期提醒、確認不回寫、跳過、刪除、逾期暫停）——**🟢 5/5**（RecurringService：日粒度到期判定＋N-7 千分位＋reminder≥3 暫停；確認 source=recurring 不回寫模板＋next_due monthly clamp；軟刪墓標） | T-F06-FE（4：badge、清單、確認 UI、暫停標示）——**🟢 4/4**（明細 badge 恆顯示（0 亦然——S2 契約）＋RecurringQueuePage（全活躍排程：到期項操作/非到期項「下期 M/d 提醒」/paused 標示）） | **schema v5** ✅（recurring_transactions） | M6 | ✅（**M6 完成併入 main e4cbd63；v0.4.9 已 tag**：部署驗證通過（Release 47.7MB＋二次啟動）；95 unit 綠） |
| F07 雲端同步 | T-F07-BE（8：補同步、LWW、每筆模式、批次、附件分流、bootstrap、GC、備份密碼——**🟢 10 情境全綠**（7 單一＋Outline 3 列）：SyncCoordinator（vault/devices/ops/blobs 佈局、pull cursor、push 打包/manifest、附件 Wi-Fi 分流）＋BundleApplier（LWW＋衝突 sync_events＋N-8）＋BackupService（每日快照＋AES-GCM 密碼＋GC 保留份數）＋AutoSyncService（sync.mode 分流）；**schema v5 落地**（sync_events 提前＋recurring 一次到位） | T-F07-FE（6：連結、立即同步、啟動同步、還原、異帳號、衝突檢視）——**🟢 6/6 macOS**（連結兩步授權／立即同步「同步中…→已同步 N 筆」／啟動自動同步 last_at／**新裝置還原兩步**（選還原→導向 Google 登入→登入同帳號→bootstrap）／異帳號空空間／衝突檢視唯讀；修 DBG-007：還原缺登入步＋harness 導航/pump 遺漏＋遮擋節流韌性） | api-spec.yaml（P2 僅對照，不改）✓；oplog packed_seq ✅；**dbml sync_entity 補 income_goals（v0.3.2）✅** | M5/M6 | ✅（**M5 收尾完成併入 main 39b5a26；tag v0.4.11 自動建立**：部署驗證通過（Release 48.0MB＋Info.plist 0.4.11＋二次啟動 DBG-004 回歸）；FE 全回歸 **10/10**；95 unit 綠；DBG-007 結案。生產接線（DriveAdapter／main() provider 注入）另於 v0.4.12 落地） |
| F08 App 鎖 | T-F08-BE（4：門檻邊界、退場狀態機、重設路徑×2）——**🟢 4/4**（AppLockController：shouldLockOnResume 純查詢＋同背景會話多次邊界探測 29/30/31s＋Clock 單一來源＋生物辨識失敗退場 ≥3 僅 PIN＋PIN 雜湊 FNV 最小實作 TODO(SP-4)＋canResetPin 授權路徑——無繞過方法設計） | T-F08-FE（5：鎖定畫面、10 秒、退 PIN、忘記 PIN、遮蔽）——**🟢 5/5 macOS**（LockGate lifecycle 鎖定閘 AppShell 層覆蓋零侵入＋LockScreen Face ID seam 成功/失敗×3 退場→PIN 鍵盤→驗證解鎖＋忘記 PIN（已連雲端 token 重設＋未連僅重置 App——資料零損失 20 筆）＋總覽 👁 隱私遮蔽 ●●●●＋pumpBackground T-H8 落地） | lock.timeout key（settings） | M7 | ✅（**M7 完成併入 main d8dd684；tag v0.4.10 自動建立**：部署驗證通過（Release 48.0MB＋Info.plist 0.4.10＋二次啟動 DBG-004 回歸）；95 unit 綠＋analyze 0＋FE 回歸 9/10（f07 已知暫停）；效能複測實測記錄 tasks.md §4.2；NFR-03 規格未定義待 PM） |
| F09 資料管理 | T-F09-BE（3：本地清空、雲端清空、不復活）——**🟢 3/3**（WipeService 本地全表清空事務＋附件刪除＋雲端 LedgerSync/ 全刪＋CloudWipedException；**不復活閘修復**：正式路徑全走 sync()，_ensureVault 會在 pull 偵測前重建 vault→復活（驗收 S9.2 #5 Critical）——device.ever_synced 旗標（pull 成功後武裝；bootstrap 亦武裝）＋vault 缺→sync() 直接拋；首次連結無旗標不誤判；95 unit 綠） | T-F09-FE（2：三重防護、加驗身分）——**🟢 2/2 macOS**（DataManagementPage 狀態機：警告（未連雲端「無雲端可還原」＋可先匯出備份檔入口）→PIN（verifyPin）→確認文字「我要清除所有資料」（不符擋下資料未清）→已連雲端加驗「重新登入雲端帳號」（帳號不符拒絕）→「已清空」＋pop 主殼空帳本；獨立引導頁屬上架前 UI 統整） | 清空=雲端資料夾刪除契約 | M7 | ✅（**M7 完成併入 main d8dd684；tag v0.4.10 自動建立**：部署驗證通過（Release 48.0MB＋Info.plist 0.4.10＋二次啟動 DBG-004 回歸）；95 unit 綠＋analyze 0＋FE 回歸 9/10（f07 已知暫停）；效能複測實測記錄 tasks.md §4.2；NFR-03 規格未定義待 PM） |
| F10 報表 | T-F10-BE（5：占比、bigram 搜尋、AND 篩選、CSV、效能）——**5/5 ✅**（TextIndex bigram＋SearchService FTS 優先 LIKE 降級＋ReportService 0.1%＋CsvExporter BOM＋NFR-01 10 萬筆 387ms） | T-F10-FE（3：圖表呈現、複合篩選、匯出提示）——**3/3 ✅**（統計分頁＋明細篩選列 chips＋匯出提示；呈現以數值文字斷言，甜甜圈視覺屬打磨） | transactions_fts（v2 ✅）；CSV 欄位契約 | M2 | ✅ |
| **F11 帳戶/分類設定＋外觀** | **T-F11-BE（8：帳戶 CRUD＋oplog、合併計算語意、刪除拒絕×2、分類 CRUD＋排序、子分類一層、外觀持久化）——✅ 全綠（112 unit）** | **T-F11-FE（10：原 8＋子分類拖曳、常用類別區——PM 2026-10-22 下午決策）——🔶 執行中** | **schema v6（T-S6）✅；data-spec v0.3.3；settings app.theme_mode ✅；內建主類別集 v2（支出 14＋收入 2，PM 定稿）✅** | **M8** | 🔶 T-F11-BE 完成；FE 10 情境執行中（含拖曳重試策略）。缺口來源：PM 走查 2026-10-22（帳戶合併計算/設定頁/外觀）＋同日下午（主類別重定義/子分類拖曳/常用類別區） |

### 4.2 依序開發的排程（對應 research §2.2 Sprint）

```
S0  ：T-H1~H9（Helper 全數紅綠燈完畢）→ T-S1 基線 migration → truth 對齊測試上 CI
S1-2：T-S1 → T-F01(BE→FE) → T-F02(BE→FE)
S3-4：T-S2 → T-F05(BE→FE) → T-F10(BE→FE) → 桌面適配（F01-S1.11/F03-S3.9）
S5  ：T-S3 → T-F04(BE→FE)
S6-7：T-S4 → T-F03(BE→FE)
S8  ：F07 之 BE（備份/還原/GC）✅ → FE（連結/還原/狀態頁）✅ 6/6（2026-10-22 DBG-007 修正後全綠）→ Google OAuth 送審（**待 PM 憑證＋main() 生產接線**：DriveAdapter/oauth/syncCoordinator 三 provider 未 override）
S9-10：T-S5 → T-F07 其餘（同步/LWW）→ T-F06(BE→FE)
S11-12：T-F08 ✅ → T-F09 ✅ → 效能複測（NFR-01~03）✅ → UI 統整 ✅（v0.4.10~13）→ 上架（憑證／商店，見 pm-actions.md）
M8（**新增：UI 對照雛型整合＋設定群**）：
  - UI-P1 總覽（01-dashboard）✅ 2026-10-22
  - UI-P2 明細（02-ledger：帳戶 chips＋篩選 chips）✅ 2026-10-22
  - UI-P3 預算（✅ 完成＋預算表單補全 S5.8）（04-budget：總預算摘要／每日可用／月底預測）☐
  - UI-P4 快記（03/10）☐／UI-P5 掃描-信用卡-設定（05/06/07）☐
  - UI-P6 分類設定頁（09 雛型已有）→ 併入 T-F11-FE ☐
  - T-S6（schema v6）→ T-F11-BE → T-F11-FE（帳戶管理＋分類管理＋外觀）
  補充（PM 2026-10-22）：前後端測試分流——頁面情境優先 widget test（~1s）；
  integration_test 只保留真平台行為（lifecycle／快捷鍵／雙殼／檔案 DB）。
  補充（PM 2026-10-20）：UI 統整留到 M7 上架前一次做——Material 3 tokens 定稿＋各頁視覺套用＋深色模式逐頁檢查＋無障礙/空狀態文案；不在各 milestone 中途做（現況各頁樣式 ad-hoc 已知）
```

**依序原則**：同一 feature 永遠 BE 先於 FE（FE 以 BE 為地基）；schema migration 先於依賴它的 feature；truth 變更先於一切。

### 4.3 修正流程（既有功能的 fix，區別於新開發）
0. 自 main 切 `fix/{issue}-{簡述}` 分支（§0.1）。
1. 在 `specs/plan/debug.md` 建立 **DBG-NNN 條目**（含最小重現步驟與嚴重度）。
2. 把重現做成**回歸情境**：加入 `tests/{frontend|backend}/Fxx.feature`（新句型先登記 `dsl.md`）→ 🔴 紅燈。
3. 最小修復 → 🟢 綠燈 → 🔵 重構。
4. **依 §7.1 同步矩陣**更新 SDD／BDD／TDD／DDD 相關檔案（truth 先行，research §6）。
5. PR（`fix(DBG-NNN): …`）→ merge → `debug.md` 結案（記錄根因）→ 更新 `tasks.md` §6 與 `session.md`。

---

## 5. truth 對齊檢查清單（每個 PR 必過；T-H9 自動化＋人工勾選）

| # | 檢查 | 自動化 | 落差處置 |
|---|---|---|---|
| 1 | drift schema（表/欄/enum/index）≡ `data-spec.dbml` | ✅ T-H9 snapshot 比對 | 🔴 補 migration 或改 dbml（走 §3 流程） |
| 2 | pubspec 依賴與版本 ⊆ `techstack.md` §2 | ✅ CI 比對腳本 | 升版需 techstack PR（架構簽核） |
| 3 | `api-spec.yaml` 僅在 P2 工作分支變更 | ✅ CI 路徑規則 | 還原；v1 不得實作其端點 |
| 4 | 新步驟句型已登記 `dsl.md` | 🔍 PR review | 補登記後才可合併 |
| 5 | FR/AC/情境 ID 出現於 PR 標題與測試標籤 | 🔍 PR review | 補標籤（追溯鍵不可斷） |
| 6 | acceptance 檔未被改動；若改動 → PM 重新簽核 | 🔍 CI 路徑規則 | 依 acceptance README §5 流程 |
| 7 | 金額/加密/同步模組變更 → PR 標註「待雙重 review」 | 🔍 review | 兩位 reviewer 核准才可合併 |

---

## 6. 任務狀態總覽（活文件）

| 區塊 | 任務 | 狀態 |
|---|---|---|
| 前置 | 專案骨架（flutter create 四平台＋Money/HLC/Balance＋CI＋README＋BDD feature 同步） | ✅（96bca5f） |
| 前置 | UI Demo 畫廊（7 畫面＋深淺色切換＋分類設定頁＋品牌虛構化 27 檔） | ✅（89571c9/01a295c） |
| Helper | T-H1 記憶體 DB fixture（sqlite3 直連 schema v1）＋T-H2 Clock | ✅（9622009 紅/b557029 綠） |
| Helper | T-H3 雲端 adapter（雙裝置拓撲模擬）＋T-H4 通知 spy＋T-H5 標準資料集＋T-H6 發票測資＋編碼器 | ✅（39be197 紅/f803eb2 綠） |
| Helper | T-H7 Gherkin runner（BE）＋T-H8 FE 掛鉤（驗證延至 M1 FE 首跑）＋T-H9 truth 對齊測試 | ✅（f803eb2） |
| Migration | T-S1 schema v1（建表＋建表回歸＋truth 對齊基線，隨 T-H1 完成） | ✅ |
| Migration | T-S2~T-S5（v2~v5，M2~M6 隨各 feature）——T-S2 ✅（81 綠）｜T-S3 ✅（信用卡/帳單/退款/分期；81 綠）｜T-S4 ✅（attachments＋遷移鏈 v3→v4＋T-H9 擴充；85 綠；merge 6501051）｜T-S5 🔵前段（sync_events 隨 F07/M5 落地＋recurring 表到位＋回歸 3 測；recurring 業務 M6） |
| Feature | T-F01-BE（8 情境：智慧預設×4／儲存事務／Undo／離線／效能——🔴→🟢 完成，每情境一 commit） | ✅（合併 ffadf09） |
| Feature | T-F01-FE（@P0 6 情境：預填／對話框／Sticky／完成／時間選擇器／復原——🔴→🟢 Windows 實跑全綠；App 主殼+快記頁+明細+總覽落地）＋production 接線（path_provider，techstack v0.3.5 PM 定案） | ✅（S1.11 @P1 @desktop 屬 M2；acceptance 手動情境留 QA 走查） |
| Feature | T-F02-BE（@BE @P0 5 情境 🔴→🟢：金額驗證／轉帳守恆＋MonthlyStatsService／儲值 transfer 語意／軟刪除＋TombstonePurgeService 30 天／還款＋creditUnpaidTotal；多幣別 @P1 @M2 deferred PM 確認） | ✅（7ef56da） |
| Feature | T-F02-FE（@FE @P0 5 情境 🔴→🟢 macOS 實跑全綠：金額驗證禁用態／快記轉帳模式＋明細樣式／儲值文案／最近刪除 30 天還原 UI（RestoreTransactionUseCase 補口＋unit test）／**S2.9 金額計算機鍵盤**（PM 增補：常駐四則運算、＝ 四捨五入整數元、macOS 視窗 800×760）；feature 檔 rootBundle 資產載入（桌面 CWD 修復，F01 同修）；69 unit＋F01-FE 回歸全綠；M1 部署驗證通過（Release 46.9MB＋檔案 DB 二次啟動） | ✅（c46df19；拆分 @P1 @M2） |
| Feature | T-F05-BE（@BE @P0 5 情境 🔴→🟢：閾值 N-1 冪等／N-2/N-3 分級＋預算用量含 pending 預扣分量／收入達標率不封頂／自訂起始日跨月週期——BudgetPeriodService＋BudgetEvaluator＋BudgetAlertService 冪等 sync 點（settings notif_state per period）＋SaveTransactionUseCase settlementStatus＋afterSave 鉤子；S5.3 規格補漏 Given 6500） | ✅（3181aab） |
| Feature | T-F05-FE（@FE @P0 5 情境 🔴→🟢 macOS 實跑全綠：進度條警示色 orange/red／超支不封鎖記帳／預扣標籤／收入目標已達成卡／通知開關閘 budget.notify_enabled——預算分頁（M2 IA 第三分頁）＋總覽收入目標卡＋共用 BudgetProgressBar；FE 情境基線自洽修正 S1 7000/S2 8320 對齊 acceptance 敘述） | ✅（b23aca1） |
| Feature | T-F03-BE（@BE @M4 @FR-S 7 情境 🔴→🟢：左 QR 77 碼切片解析／右 QR 明細合併（deflate+Base32 codec）＋解碼失敗留空邊界／非發票回退 null＋空白確認卡 TransactionDraft.blank／OCR 欄位抽取 heuristics（總額關鍵字 0.9·商家頂部 0.8·日期民國 0.5 西元 0.9·統編無候選留空）／附件壓縮內容定址（image 縮 1600px＋JPEG q70＋crypto sha256→blobs/{sha256}＋attachments 列 oplog 同 transaction）／離線全本機解析／NFR-02 抽取計時——InvoiceQrParser＋ReceiptFieldExtractor＋AttachmentStore；dsl v0.6 +19 句型；規格修正：acceptance/feature 測資字串 76→77 碼（總計段補 0，對齊欄位對照表與 T-H6 金測；acceptance 變更待 PM 複核）＋S7 效能句型「入庫耗時」→「OCR 欄位抽取耗時」；techstack v0.3.7（image 4.12.0＋crypto 3.0.7，PM 簽核 2026-10-21）；DBG-005 結案（save_split 順序依賴，斷言改順序無關，10 連綠） | 🟢（7/7；FE 待） |
| Feature | 首次啟動播種（內建分類集＋預設現金帳戶；M1 過渡——帳戶/分類管理 UI 屬 F02；oplog 同交易契約） | ✅（8545bc5） |
| 對齊 | §5 清單自動化（pubspec/schema ✓ 已上 CI）；PR review 項人工 | 🟢 |
| 發佈 | v0.1.0、v0.2.0（自動標籤；**Release 產物從未成功**——流水線鏈式缺陷）；**v0.4.3（DBG-004）／v0.4.4（首次啟動播種＋發佈格式定案：版本化檔名＋Inno Setup per-user exe／DMG／未簽名 IPA／軟體內版本）**；v0.4.5~v0.4.20（UI 對照雛型＋emoji 圖示制＋桌面三欄殼＋分類體系 v2） | ✅（v0.4.0~0.4.2 為修復迭代，v0.4.2/v0.4.0 壞包待刪） |
| Fix | **DBG-008 清空資料無 PIN 鎖死**（PM 實機回報）：`AppLockController` 建構子 `pin` 可選＋`hasPin`；清空流程無 PIN 跳過 PIN 步驟；widget 護欄＋F08-BE 回歸 2 情境；同步 SPEC FR-O3／SDD §7.2/§7.3／BDD F9／dsl v1.8／acceptance F09／debug.md | ✅（v0.4.20） |
| Feature | **快記 v4＋資料管理（PM 2026-10-24）**：①模式列＝支出/收入/轉帳（拆分→明細編輯、預算→預算頁）；三模式**類別各自獨立**②**兩平台同版面**（`MainCategoryGrid` 共用）＋手機保留計算機③鍵盤改版（C/⌫/OK、移除＝、＋移位、0 跨兩格、即時求值）④明細商家欄＝商家、分類＝主類別圖示＋子類別名⑤分類彈窗「＋新增」兩平台可用⑥**資料管理範圍勾選**＋`WipeService.wipeScoped`（刪除＋oplog；回到系統預設值＝全清空＋重播種） | ✅（fix 分支） |
| Feature | **統計頁 v2＋原型/DEMO（PM 2026-10-24）**：新增原型 `11-stats.html`＋DEMO「11 統計」；統計頁＝月份列（stats-month-prev/next）＋三卡（支出/收入/淨額）＋甜甜圈＋**色點圖例**＋月趨勢（既有數值文字契約不變）；計算機 DEMO 文案/模式列更新 | ✅（fix 分支） |
| Fix | **明細頁對齊雛型（PM 2026-10-24）**：手機＝分日群組（今天／昨天／MM/DD）＋每日小計（淨額）＋分類圖示圓＋副標（時分·帳戶·分類·備註·標籤）＋金額千分位（支出紅／收入綠／轉帳中性）＋待確認琥珀 pill＋帳戶 chips teal；桌面（≥900px）＝表格（日期|類型|分類|商家／對象|帳戶|金額）。決策：**單一份 BDD ＋平台對照**（BDD §2.1）。同步 SDD §8.1／F02 acceptance S2.11／dsl v1.14／雛型 02·08 | ✅（fix 分支待 PM 驗收） |
| Fix | **明細列顯示補齊＋PC 分類欄（PM 2026-10-24）**：`TxTile` 補分類圖示圓（子類別取主類別）＋標題退回分類名＋副標「時間 · 帳戶 · 分類 · 備註」；轉帳 🏦／儲值 📲／拆分 🔀；PC 快記面板分類欄與手機一致（`desktop-quick-category`）。同步 BDD F2／F02 acceptance S2.11／SDD §8.1／dsl v1.13／雛型 02/08 | ✅（隨快記 v3 一併發佈） |
| Fix | **子類別無圖示（PM 2026-10-24）**：子類別不擁有 icon——顯示取主類別圖示；分類管理子列不顯 emoji／子類別表單無圖示選項（清空入庫）；快記分類欄「主 emoji＋子名」／彈窗右欄僅名稱／預算子格僅名稱；PC 面板高亮所屬主類別；UI_DEMO 展開態子列＋規則⑤；雛型 09 v4。同步 SPEC FR-B1／SDD §5.6／BDD F11／F11 acceptance S11.2-12／dsl v1.12 | ✅（隨快記 v3 一併發佈） |
| Feature | **快記 v3（PM 2026-10-24 回饋）**：分類選擇**彈窗**（上常用／左主類別／右子類別；＋置欄頂即建即選）＋**備註**欄（手機／PC）＋**記住上次**（`QuickEntryMemory`：選子分類帶入上次金額/帳戶/商家，settings 本機記憶）；PC 面板補日期列/帳戶/商家/備註（保留三欄分類格）。同步 SPEC FR-Q4/Q5／SDD §5.1／BDD F1／F01 acceptance S1.12-13／dsl §4.6／雛型 03/10/08 | ✅（待 PM 預覽確認後發版） |
| Fix | **DBG-012／DBG-013 快記第二輪回饋（PM 2026-10-25）**：①**三欄主類別格全面退役**（手機＋桌面；`MainCategoryGrid` 刪除——分類一律「分類」欄→彈窗）②**桌面面板常駐計算機鍵盤**（與手機共用 `AmountKeypad`；原大按鈕移除；`quickEntrySaveEnabled` 抽為共用）③分類彈窗**「⭐ 常用類別」**（左欄最上；右欄常用類別文字——主類別＝名稱／子類別＝主 emoji＋子名；原 chips 退役）④手機對齊 **03**（金額置中＋「帳戶：X（Sticky）」＋「本次已記 N 筆」；附件 📷 依 PM 決策先不做）⑤**分類圖示唯一來源** `category_display.dart`（子類別 `icon=''` 回退主類別；非庫內→🏷️；套用 6 處——修「快記與類別設定不同」）。新增 `category_display_test` 3＋更新 `quick_entry_layout_test`／`desktop_shell_test`／`quick_entry_ui_test` | ✅（fix 分支待 PM 驗收） |
| Fix | **DBG-010 最近刪除看不到明細刪除（PM 2026-10-25 實機）**：`tx_edit_sheet` 刪除/拆分後只 `invalidate(ledgerProvider)` → `recentDeletionsProvider` 回舊快取。修復：刪除/拆分、快記「復原上一筆」（軟刪除）、資料管理 `wipeScoped` 成功後一律失效 `recentDeletionsProvider`（資料管理另失效 ledger/分類/帳戶） | ✅（fix 分支待 PM 驗收） |
| Fix | **DBG-011 快記手機版版面不符雛型（PM 2026-10-25 實機）**：對齊 **03／10 雛型**——①移除手機頁三欄快捷格（分類不再平鋪；改「分類」欄→彈窗；三欄格僅**桌面面板** 08）②欄位順序回正（模式→金額→日期→帳戶/分類→商家→備註）③帳戶｜分類**同一列兩欄**（`IntrinsicHeight` 等高）④鍵盤第一排 OK **跨兩格**（4 格對齊）⑤金額**右對齊**＋「金額（TWD・整數元）」說明⑥欄位統一圓角方框；新增回歸護欄 `test/presentation/quick_entry_layout_test.dart`（4 情境）；同步 dsl §4.7 v1.19／debug.md | ✅（fix 分支待 PM 驗收） |
| Feature | **「最近刪除」直接刪除（PM 2026-10-24 需求增補）**：①單筆 `recent-delete-purge-{id}`＋②清空全部 `recent-delete-purge-all`，皆**二次確認**（`recent-delete-purge-confirm`／`-cancel`）→ `PurgeTombstoneUseCase`（`AppDatabase.purgeTombstoneById`／`executeAll` 走同一 30 天清除路徑）＝**實體刪除、oplog 墓標保留**（同步安全）；未刪除者拋 StateError（防誤刪）、清除後回 0（冪等）③原型 `12-recent-deletions.html`＋DEMO「12 最近刪除」。TODOLIST：BE ✅／UC ✅／FE ✅／測試 ✅／雛型 ✅／DEMO ✅／文件 ✅／驗證 ✅ | ✅（fix 分支待 PM 驗收） |
| Fix | **DBG-009 分類設定變更不連動＋子分類無法編輯**（PM 實機回報）：`_refresh` 失效衍生快取（expense/income/ledger）＋新增 `incomeCategoriesProvider`；子列 `cat-edit-{name}`（改名/emoji/顏色）；emoji 庫 33；同步 SPEC FR-B1／SDD §5.6/§7.2／BDD F11／acceptance F11 S11.2／ui 09／debug.md | ✅（待 v0.4.21 發佈） |

### 6.1 進行中工作清單（TODOLIST；PM 2026-10-25 回饋批）

> PM 指示：**動手前先列 TASK／TODOLIST**；狀態：⬜ 未開始／🟨 進行中／✅ 完成。

| # | TASK | 範圍（檔案／雛型） | 驗收 | 狀態 |
|---|---|---|---|---|
| T1 | **兩平台移除「個別主類別選項」**（三欄格退役；`MainCategoryGrid` 刪除） | `main_shell_page.dart`（移除 `MainCategoryGrid`）；雛型 `08` 同步 | widget test：桌面殼面板無 `MainCategoryGrid` | ✅ |
| T2 | **電腦版面板版面／按鈕對齊 `10-quick-entry-calc.html`**（PM 決策：**面板也要有計算機鍵盤（OK 跨兩格）**、移除獨立大按鈕） | `main_shell_page.dart`；雛型 `08`／`10` | 截圖對照雛型 | ✅ |
| T3 | **分類圖示一致性**：抽出共用 `categoryEmojiOf()`（自身 icon 在圖示庫→用；否則取主類別；否則 🏷️），套用至 類別設定／快記彈窗／快記手機分類欄／**快記桌面分類欄**／明細列／最近刪除列。修 `icon=''` 使 `??` 不回退之缺陷 | 新 `category_display.dart`＋6 處呼叫端 | unit：子類別→主類別 emoji；非庫內代碼→🏷️；各頁一致 | ✅ |
| T4 | **手機版改以 `03-quick-entry.html` 為準**（非 10）：金額**置中**大字＋「帳戶：現金（Sticky）」小字；備註列；「本次已記 N 筆」（PM 決策：**附件 📷 先不做**——屬 F03） | `quick_entry_page.dart`；雛型 `03` | widget test：金額 `TextAlign.center`＋Sticky 小字＋計數文字 | ✅ |
| T5 | **手機版「商家」「備註」為輸入欄位**（可輸入） | `quick_entry_page.dart` | widget test：兩者為 `TextField` 且可 `enterText` | ✅ |
| T6 | **分類彈窗「常用類別」**：左欄**最上方**加「⭐ 常用類別」項；選它→右欄顯示**常用類別文字**（PM 決策：全部列出含主類別——主類別＝名稱／子類別＝主 emoji＋子名）；移除上方分散的常用 chips | `category_picker_dialog.dart`；雛型 `03`（彈窗機） | widget test：`picker-freq`（⭐）＋右欄常用清單；舊 `picker-recent-*` 退役 | ✅ |
| T7 | 雛型／DEMO 同步（03／08／10＋畫廊）；dsl keys 更新 | `specs/plan/ui/*`、`demo/*`、`dsl.md` | 瀏覽器對照 | ✅ |
| T8 | 文件：SPEC／SDD／BDD／acceptance／tasks／session／`debug.md`（DBG-012 圖示不一致、DBG-013 面板項目） | 各文件 | 同步矩陣 §7.2 | ✅ |

- 狀態更新規則：🔴/🟢 由 CI 與 PR 自動可推導；🔵 與 ✅ 由開發者於 PR 描述更新；每 Sprint 結束回寫本表（對應 research §2.2 出口條件）。

---

## 7. 功能修正的文件同步（SDD／BDD／TDD／DDD）

> **規則**：任何功能修正（缺陷修復或需求調整）合併前，必須依下表同步對應文件；**未同步 = PR 不可合併**（CI＋review 雙重檢查）。條目追蹤使用 `specs/plan/debug.md`。

### 7.1 四類文件定位

| 類別 | 檔案 |
|---|---|
| **SDD（設計）** | `SDD.md`；truth（`techstack.md`／`api-spec.yaml`／`data-spec.dbml`） |
| **BDD（行為）** | `BDD.md`；`specs/plan/features/acceptance/*` |
| **TDD（測試驅動檔）** | `specs/plan/tests/{frontend,backend}/*.feature`；`dsl.md`；`test/`、`integration_test/` 同步副本 |
| **DDD（領域）** | `lib/domain/**`（實體/服務）＋對映文件：SDD §4 資料模型、SDD §5 服務、`data-spec.dbml` |

### 7.2 同步矩陣（依變更類型）

| 變更類型 | SPEC | SDD | BDD | TDD | DDD | truth | 其他 |
|---|---|---|---|---|---|---|---|
| 需求／行為變更 | ✔ FR 條文 | ✔ §5 模組 | ✔ 情境 | ✔ FE/BE feature | ✔ 領域服務文件 | 視影響 | acceptance 重簽 |
| schema 變更 | — | ✔ §4 摘要 | ✔ 若影響情境 | ✔ 測試 fixture | ✔ lib/domain 實體 | ✔ **data-spec.dbml 先行** | migration（§3） |
| API／P2 變更 | — | ✔ §5.5/§12 | — | — | — | ✔ api-spec.yaml | — |
| 套件／stack 變更 | — | ✔ §3 | — | — | — | ✔ techstack.md 先行 | pubspec |
| UI 變更 | — | ✔ §8 | — | ✔ FE feature | — | ✔ specs/plan/ui/ 雛型 | acceptance 走查 |
| 新步驟句型 | — | — | — | ✔ **dsl.md 先行** | — | — | — |
| 缺陷修復（fix） | ✔ 若行為定義變 | ✔ 若設計變 | ✔ 新增回歸情境 | ✔ 回歸情境 | ✔ 若領域規則變 | 視影響 | debug.md 結案 |

### 7.3 Debug 流程（詳見 `specs/plan/debug.md`）
1. `debug.md` 建條目 DBG-NNN → 2. 最小重現做成回歸情境（🔴）→ 3. 定位與實驗（記錄於條目）→ 4. 最小修復（🟢/🔵）→ 5. 依 §7.2 同步 → 6. commit `fix(DBG-NNN): …` → 7. 結案（記根因）。
- 分支：`fix/{issue}-{簡述}`；每條目**至少一個回歸情境**（防止復發）；Blocker/Critical 結案需 reviewer 核准。
