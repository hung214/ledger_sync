# Debug Todolist（除錯追蹤活文件）

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.3（初版） |
| 定位 | 開發／測試／QA 發現缺陷時的**追蹤清單**；流程規範見 `specs/plan/tasks.md` §4.3／§7 |
| 嚴重度 | Blocker / Critical / Major / Minor（定義見 `specs/plan/features/acceptance/README.md` §4） |
| 分支 | 每條目一條 `fix/{issue}-{簡述}`；commit 格式 `fix(DBG-NNN): …` |

---

## 1. 何時開條目

- 情境測試 🔴 失敗且 **30 分鐘內無法定位**（避免盲改；能立即修的小錯不必開條目）。
- QA 驗收（acceptance 走查）回報的缺陷。
- 真機與 CI 行為不一致、truth 對齊測試（T-H9）紅燈且非預期。

## 2. Debug 標準流程（每條目七步）

1. **建條目**：複製 §3 模板，取得編號 DBG-NNN。
2. **最小重現**：把重現寫成**回歸情境**加入 `specs/plan/tests/{backend|frontend}/Fxx.feature`（新句型先登記 `dsl.md`）→ 🔴。
3. **定位**：列嫌疑模組／最近相關 commit（必要時 bisect），每次實驗記錄結果於條目。
4. **假設→修復**：最小修復，不做順手改。
5. **回歸綠燈**：新回歸情境 🟢＋既有測試不被破壞。
6. **文件同步**：依 `tasks.md` §7.2 矩陣更新 SDD／BDD／TDD／DDD 相關檔案（truth 先行）。
7. **結案**：commit `fix(DBG-NNN): …` → merge → 本表標 ✅ 並記錄**根因**。

## 3. 條目模板（複製使用）

```
### DBG-NNN｜{一句話摘要}
- 日期／回報者：
- 嚴重度：Blocker|Critical|Major|Minor
- 來源：Fxx-BE/FE 情境 | AC-xx | QA 走查 | T-H9 truth 對齊
- 重現：{最小步驟}
- 回歸情境：tests/{backend|frontend}/Fxx.feature → Scenario {名稱}
- 定位：{嫌疑模組/commit → 實驗 1：結果 → 實驗 2：結果}
- 根因：
- 修復：{檔案與改動要點}
- 同步（§7.2）：SDD[ ] BDD[ ] TDD[ ] DDD[ ] truth[ ]
- 狀態：🔴 重現中 / 🔍 定位中 / 🔧 修復中 / ✅ 結案
```

## 4. 追蹤表（活文件，新條目加在上面）

| ID | 日期 | 嚴重度 | 來源 | 摘要 | 分支 | 回歸情境 | 狀態 | 根因 |
|---|---|---|---|---|---|---|---|---|
| DBG-010 | 2026-10-25 | Major | PM 實機走查（fix 分支預覽） | **明細刪除的交易不會出現在「最近刪除」**：`tx_edit_sheet` 刪除後僅呼叫 `widget.onChanged()`（明細頁傳入 `invalidate(ledgerProvider)`），**未使 `recentDeletionsProvider` 失效**——該 provider 一旦在同一 App 生命週期內建過（例如先前開過最近刪除頁）即持續回舊快取（空清單）→ 使用者看不到剛刪的墓標、無法還原 | fix/quick-entry-v3-ledger-display | `test/presentation/recent_deletions_page_test.dart`（清單／單筆永久刪除／清空全部）＋`test/application/purge_tombstone_use_case_test.dart`；同根因一併掃描：快記「復原上一筆」、資料管理範圍刪除 | ✅ 結案 | Riverpod 快取未失效（**DBG-009 同族**）。修復：`tx_edit_sheet` 刪除／拆分、`quickEntryController.undoLast`（復原＝軟刪除）、`data_management_page.wipeScoped` 成功後一律 `invalidate(recentDeletionsProvider)`（資料管理另失效 ledger／分類／帳戶） |
| DBG-016 | 2026-10-29 | Major | PM 實機走查（PC 版） | **PC 版快速記帳快捷鍵「沒有反應」**：⌘N／Ctrl+N 在面板**已開啟**（桌面預設常態開啟）時只執行「設為顯示」→ 畫面毫無變化、**沒有切換效果**（PM：快捷只有展開，沒有收起來） | fix/quick-entry-v3-ledger-display | `test/presentation/desktop_shell_test.dart` 新增情境（注入 Ctrl+N → 收合；再按 → 展開） | ✅ 結案 | 2026-10-26 把桌面快捷鍵從「推入整頁」改為「開啟右側面板」時，只做了單向開啟（`_desktopQuickOpen = true`），未與工具列鈕的切換行為一致。修復：⌘N 改為**開／收切換**（與工具列鈕同）+ 開啟時**聚焦金額欄**（可見回饋）；另補金額欄 **Enter＝儲存**（復原原按鈕「OK 儲存（Enter）」承諾）。全 App 快捷鍵僅 2 組：⌘N（快記）、⌘⇧S（掃描） |
| DBG-015 | 2026-10-27 | Minor | 助理自查（統計頁 v4 切換功能 golden 核對時發現） | **統計頁「預設月份」可能不是最新有資料月份**：月份清單比較子誤寫 `b.$2.compareTo(b.$2)`（**自我比較恆 0**）→ 清單**未依月份排序** → 預設取決於 set 插入順序（＝DB 回傳順序）。單月資料時看不出來；多月資料時可能停在舊月份（例：停在 9 月而非 10 月） | fix/quick-entry-v3-ledger-display | `test/presentation/stats_page_test.dart` 新增情境⑤（先種新月份再種舊月份 → 斷言預設＝最新月且顯示該月資料） | ✅ 結案 | 原比較子 typo（`b.$2` 寫成與自身比較）；修復 `b.$2.compareTo(a.$2)`。**暴露方式**：淨額檢視 golden 出現「整圈紅」＝只取到 9 月的 5,000 支出 → 追查選定月份才發現 |
| DBG-014 | 2026-10-26 | Major | PM 實機走查（PC 版） | ①**工具列「快速記帳」鈕整頁切換到快記頁**（PC 應為右側面板**顯示/隱藏**）②**PC 面板計算機點選後沒有效果** | fix/quick-entry-v3-ledger-display | `desktop_shell_test`（工具列鈕切換面板；鍵盤輸入→金額欄/controller 同步）＋`quick_entry_layout_test` | ✅ 結案 | ①`_openQuickEntry` 一律 `Navigator.push`（桌面亦然）→ 改為桌面寬度 ≥900 時切換 `_desktopQuickOpen`（工具列鈕文案/圖示反映狀態；⌘N＝開啟）②桌面面板 `onExprChanged` 只 `setState(_expr)`，**未寫回金額欄與 controller**（手機版有寫）→ 補 `_onKeypadExpr`（同手機契約） |
| DBG-013 | 2026-10-25 | Major | PM 實機走查（fix 分支預覽） | **快記版面／互動與雛型不符（第二輪）**：①**電腦版面板不應有個別主類別選項**卻有整塊三欄類別格（PM：分類一律由「分類」欄開彈窗）②電腦版面板**缺常駐計算機鍵盤**（PM：不管右邊或按鈕顯示都與 10 不符）③手機版應以 **03** 為準而非 10（金額**置中**＋下方「帳戶：X（Sticky）」小字、「本次已記 N 筆」） | fix/quick-entry-v3-ledger-display | `quick_entry_layout_test.dart`（金額置中＋Sticky 小字＋順序）、`desktop_shell_test.dart`（面板**無**類別格＋鍵盤 OK 儲存入庫） | ✅ 結案 | 三欄格自快記 v4 起被同時放到手機與桌面（當時誤記為「兩平台同版面」）；桌面面板亦一直缺鍵盤（原為獨立大按鈕）。修復：**刪除 `MainCategoryGrid`**（兩平台皆不平鋪）；桌面面板改用共用 `AmountKeypad`（`quickEntrySaveEnabled` 亦抽為共用）；手機改對齊 03 |
| DBG-012 | 2026-10-25 | Major | PM 實機走查（fix 分支預覽） | **分類圖示跨頁不一致**：快記（手機／桌面）與明細列的分類圖示常「空白或顯示原始字串」，與**類別設定**所示不同。根因①**子類別 `icon` 入庫為空字串 `''`（非 null）**，各處寫 `icon ?? 主類別.icon` → `??` 永不回退 → 無圖示②非圖示庫代碼（如新建主類別預設 `shopping_basket`）在類別設定走 `_emojiOf`→🏷️，其他頁**直接印原始字串** | fix/quick-entry-v3-ledger-display | 新增 `test/presentation/category_display_test.dart`（主類別／子類別空字串回退／非庫內→🏷️；3 情境）＋明細／快記 widget test | ✅ 結案 | 同一規則在 6 處各自實作且不一致。修復：抽出 `category_display.dart`（`categoryEmojiOf`／`categoryLabelOf`／`categoryIndex`）為**唯一來源**，套用類別設定／快記手機＋桌面／彈窗／明細列／最近刪除列 |
| DBG-011 | 2026-10-25 | Major | PM 實機走查（fix 分支預覽） | **快記手機版版面與雛型 03／10 不符**：①金額以下多出**三欄主類別快捷格**（03 v4／10 明定「分類**不再平鋪**」——分類＝「分類」欄→彈窗）②該格把「日期」擠到帳戶之後（雛型順序：模式→金額→**日期**→帳戶/分類→商家→備註）③帳戶／分類分成兩列（雛型＝**同一列兩欄**）④計算機第一排 OK **僅 1 格**（雛型 `grid-column:span 2`＝4 格對齊）⑤金額置中、無「金額（TWD・整數元）」說明（雛型＝**右對齊**＋說明） | fix/quick-entry-v3-ledger-display | 新增 `test/presentation/quick_entry_layout_test.dart`（4 情境：無三欄格／OK 跨兩格／帳戶｜分類同列＋欄位順序＋金額右對齊／轉帳來源｜目標同列） | ✅ 結案 | 快記 v4 時把三欄格一併放上手機頁（當時記為「兩平台同版面」），但雛型 03／10 明定手機**不平鋪**、三欄格僅**桌面面板**（08）；OK 跨兩格自 v4 起一直未落實。修復：手機頁移除 `MainCategoryGrid`（欄位順序回正）；帳戶｜分類改 `IntrinsicHeight`＋`Row` 兩欄（**等高**）；`_pickerField` 與分類欄統一圓角方框；鍵盤 OK `flex: 2`；金額 `TextAlign.end`＋說明文字 |
| DBG-009 | 2026-10-23 | Major | PM 實機走查（F11-FE） | 分類設定的變更**不連動其他頁面**＋**子分類無法編輯**。①設定→分類管理改主/子分類名稱或 emoji 後，快記分類格/預算頁/明細列仍顯示舊名稱/舊圖示（分類管理頁本身因直接讀 DB 而正常）——`_refresh()` 僅對本頁 `setState`，**未使 `expenseCategoriesProvider`／`ledgerProvider` 快取失效**。②子分類列只有 🗑，無編輯入口→無法改名/換 emoji/換色（v0.4.20 實機版本） | —（PM 直接回報；修復併 main `6f7be90`） | `test/presentation/category_settings_page_test.dart`（子分類編輯：改名＋換 emoji＋**全域 provider 讀到新值之失效驗證**） | ✅ 結案 | ①Riverpod `Provider` 快取：變更後未 invalidate → 他頁讀舊值（**FE 狀態傳播疏漏，非 DB 問題**——PM 疑問澄清：資料為本地 SQLite 持久化）②子列缺編輯 affordance。修復：`_refresh` 加 `invalidate(expenseCategories/incomeCategories/ledger)`＋新增 `incomeCategoriesProvider`；子列加 `cat-edit-{name}`；emoji 庫 33（🍰） |
| DBG-008 | 2026-10-23 | Major | PM 實機走查（F09-FE 未覆蓋之境） | **從未設定 PIN 的裝置無法清空資料**：設定→資料管理→清空資料→警告→下一步→要求輸入 PIN，**任何輸入皆「PIN 不正確」**→永遠過不了（PM：我沒設過 PIN 怎麼會有 PIN？）。根因：`verifyPin` 取 `lock.pin_hash`（未設定＝null）與 `_hash(pin)` 比對 → `null == hash` 恆 false；且 `AppLockController` 建構子**強制**寫入 pin_hash（假定必已設定 PIN） | —（PM 直接回報；修復併 main `64ab635`；隨 v0.4.20 發佈） | `test/presentation/data_management_wipe_test.dart`（無 PIN→跳過 PIN 步驟／有 PIN→維持關卡）＋F08-BE「PIN 未設定/已設定判定」 | ✅ 結案 | 三重防護規格未涵蓋「無 PIN 裝置」：建構子強制種 PIN＋null 比對恆 false。修復：建構子 `pin` 改可選（未提供不寫 hash）＋`hasPin` getter；`DataManagementPage` 依 `hasPin` 決定下一步（無 PIN→直接確認文字）；acceptance S9 步驟 2 已補 |
| DBG-007 | 2026-10-22 | Major | F07-FE 情境（M5 收尾回頭） | F07-FE 6 情境無法完成（三項複合）。①**還原流程缺「導向 Google 登入」步**：`SettingsSyncPage._restore()` 一步直呼 `oauthProvider()`，未渲染 `oauth-approve`——違反驗收 **S7.4 #1→#2**（選「從雲端還原」→**導向 Google 登入**→登入同帳號）→ harness「登入同一帳號」tap 0 widgets（程式碼留半成品空區塊佐證）。②**harness 導航/pump 遺漏**：S5 未先導航同步設定頁（停在主殼→`restore-cloud` 不可達）；S6 的衝突 Given 與 `開啟同步狀態頁` 未 `_ensureApp`（container 為前一情境殘留、樹停舊頁→`app-settings` 0 widgets）。③**macOS 遮擋節流**：視窗非前景/被遮擋時 display link 暫停→render tree 陳舊→tap 落空→`_linking` spinner 永動→`pumpAndSettle` 10 分逾時 | feature/F07-cloud-sync-fe | f07_cloud_sync_test（S1-S6 全綠，00:12） | ✅ 結案 | ①實作漏規格兩步（M5 WIP 未完成）②harness 在 M5 暫停時 S4/S5/S6 未驗，缺陷未被發現③環境層：**聚焦除錯測試證明按鈕在樹上、rect 正確、但 `hitTestOnBinding` 為空路徑**＝frame 陳舊（非產品邏輯） |
| DBG-006 | 2026-10-21 | Minor | F03-FE 完成後 FE 全回歸（f01 紅） | `f01_quick_entry_test`「使用者位於明細頁」tap 失敗：`Found 0 widgets with text "明細" descending from NavigationBar`——finder 綁死窄殼（NavigationBar），而 macOS Debug app 之 NSWindow autosave frame 已漂移至 ≥900px（F10 桌面殼時代的手動 1180×740 被 autosave 記住，跨同 bundle id 之 Debug/Release 實例共享）→ LayoutBuilder 分殼為 Rail（無 NavigationBar）。M3 全綠→本輪紅＝frame 漂移後首跑 | —（測試基建，隨 F03 分支修） | 修復即回歸：finder 改 `find.byKey(Key('nav-{page}'))`（雙殼皆有 key——F10 輪「nav keys 雙殼相容」教訓之補遺，f01 當時未跟進） | ✅ 結案 | 測試殼相依 finder＋macOS 視窗 frame autosave 跨實例漂移；f01 修復後 FE 回歸 6/6 全綠（f03/f04/f05/f10/f02/f01） |
| DBG-005 | 2026-10-20 | Minor | T-S4 全量測試（併行） | `save_split_transaction_test` 第 1 情境於全量跑中三度間歇失敗（~3/50），錯誤均為 `Expected: <600> Actual: <400>`（rows[0].amountMinor）。**根因**：斷言隱式依賴 `allTransactions()` 之 `ORDER BY occurred_at, id`——兩筆拆分子交易同 occurredAt，陳列順序由 UUIDv7 id 字典序（＝時間戳序）決定；系統時鐘微回退（NTP slew，並行負載下較易）使後生成者 id 較小 → 順序翻轉 rows[0]=第二筆（400）。屬**測試順序依賴缺陷**（拆分子交易陳列順序非契約），非產品 bug | —（測試基建，未開 fix 分支） | 修復即回歸：斷言改**順序無關**（金額/分類集合 {600,400}/{c-food,c-shop}，語意不變——兩筆金額皆在＋同群組＋oplog 兩筆）；證據 log `dbg005_loop_7.log`（+24 -1, line 27） | ✅ 結案 | 測試對非契約細節（UUID 字典序）斷言；環境層時鐘微回退為觸發器。2026-10-21 修復＋驗證 10 連跑 |
| DBG-004 | 2026-10-19 | Critical | 本地部署實測（第二次啟動） | 檔案 DB **第二次開啟即崩潰**：`_migrate()` 無條件重跑 `CREATE TABLE`（無 IF NOT EXISTS、無 schema 版本閘）→ "table accounts already exists" → main() 啟動即拋錯。in-memory 測試每案例皆全新 DB，未覆蓋「重開既有檔案 DB」 | fix/dbg-004-db-reopen | db_fixture_test 新增「DBG-004：既有檔案 DB 重新開啟不崩潰且資料延續」（紅：SqliteException → 綠） | ✅ 結案 | 遷移無冪等/版本控制；修復：`_migrate()` 加 `PRAGMA user_version` 閘＋既有表偵測（交易式 DDL 全有全無，偵測可靠），使用者既有 DB 開啟即自動補標版本；DDL 字串不動（T-H9 truth regex 相容）；多版本遷移器隨 T-S2 落地 |
| DBG-003 | 2026-10-19 | Critical | 本地部署實測（v0.4.0 Windows Release） | 空帳本（全新安裝、零帳戶）首頁正常，點快記 → 整頁灰屏：`QuickEntryPresetService._firstActiveAccount()` 對空帳戶清單取 `.first` → StateError → 頁面建構拋例外（Release 呈現灰屏） | fix/dbg-003-empty-ledger | BE 情境「智慧預設_空帳本不崩潰」（紅：Bad state: No element→綠）＋FE 情境「空帳本開啟快記不崩潰」（灰屏→顯示選擇帳戶＋儲存禁用） | ✅ 結案 | FE 情境 Background 一律先種帳戶，零帳戶邊界未覆蓋；修復：`QuickEntryPreset.account` 改可空、`_firstActiveAccount()` 空清單回退 null（UI 顯示「選擇帳戶」、儲存禁用）——帳戶建立 UI 屬 F02 |
| DBG-002 | 2026-10-18 | Major | 本地部署建置（flutter build windows） | ①專案路徑含非 ASCII（記帳）→ MSBuild 讀不到 app.dill，原生建置失敗 ②flutter_secure_storage_windows 需 atlstr.h（VS C++ ATL 元件缺） | fix/TR-8-windows-build | Windows release 建置＋啟動冒煙（本輪通過） | ✅ 結案 | ①路徑非 ASCII：曾以 ASCII clone（finora-build）建置；**已根治：2026-10-18 repo 遷移至 ASCII 路徑 `E:\opencode\finora`，`dart analyze`／56 測試／Windows Release 建置（81.9s）全數直接通過（遷移後需 `flutter clean` 清含舊路徑的 CMakeCache）** ②ATL 元件缺：TR-8（secure_storage/local_auth 移至 M2，安裝元件後回歸） |
| DBG-001 | 2026-10-18 | Major | T-H1 紅綠燈（drift codegen） | build_runner/drift 與 Dart 3.13.5 工具鏈不相容：analyzer 7.x 序列化 SDK dot-shorthand 崩潰；dart_style 3.1.13+ 需 Dart 3.14 fe types（LabelReference 等）；build_runner 2.16.x pub cache 提取損壞、2.17.1 與 json_serializable 衝突 | feature/T-H-test-helpers | tests 依新 DB 邊界改寫（33 情境綠） | ✅ 結案 | 環境工具鏈問題（非程式缺陷）；過渡方案 sqlite3 直連（research TR-7、techstack v0.3.2），M1 前於 CI 重試 drift 回歸 |
| DBG-000（格式範例） | 2026-10-18 | Major | F04-BE 結帳歸屬 | （範例）卡B 當天消費誤入本期 | fix/dbg-000-example | F04-BE 新增回歸情境 | ✅ 結案 | （範例）boundary_rule 未傳入 period 計算 |

> DBG-000 僅示範欄位格式，非真實缺陷；第一筆真實條目由 DBG-001 起。

## 5. 結案規則

- 必附**回歸情境**且併入 CI（對應標籤分級：P0 缺陷的回歸＝PR gate）。
- 行為定義有變 → SPEC/SDD/BDD 同步（`tasks.md` §7.2），acceptance 變更需 PM 重簽。
- Blocker／Critical 結案需另一位 reviewer 核准；結案後條目**不刪除**（留作根因資料庫）。
