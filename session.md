# Session 工作交接（session.md）

| 項目 | 內容 |
|---|---|
| 用途 | **休息／中斷工作前**記錄當前進度，下次開工快速恢復；配套規範見 `specs/plan/tasks.md` §0 |
| 原則 | ⓪**發佈前必經「本地預覽＋PM 親眼確認」**（PM 2026-10-23：未經預覽簽認不得 push tag；預覽形式＝UI_DEMO 畫廊/雛型 HTML/實機安裝，三者擇一並截圖或口頭確認）①離開前必填「目前快照＋下一步」②狀態同步回 `tasks.md` §6（🔴/🟢/🔵/✅）③工作變更必先 commit（或明確標註 WIP 原因）④**本地部署驗證**：整體軟體所有測試寫完＋全量綠燈後做**一次**（非每個功能做完就部署；PM 2026-10-20 指示），通過才 push ⑤執行每個任務前列出 TASK/TODOLIST 讓 PM 可見（PM 2026-10-19 指示）⑥**FE integration test 暫停**（PM 2026-10-24：多項 UI 尚在修正，**先不要跑 FE 測試**——待 PM 指示再恢復；檔案保留不刪）⑦**每次發行版必標註本版修改**（PM 2026-10-26）：發版前於 `CHANGELOG.md` 新增該版區段，CI 自動帶入 GitHub Release 說明——詳見 **§1.1**⑧**工作流程：每項修改建新分支＋一次 MR 到 `ios-pwa`**（PM 2026-11-23 指示）：`git checkout -b feat/xxx` → 修改＋commit → `git push origin feat/xxx` → **MR 到 `feature/ios-pwa`**（不可直接合併 main）。全部工作完成並經 PM 確認後，再統一 MR `feature/ios-pwa` → `main`。**禁止直接在 feature/ios-pwa/main 上修改＋推送**。 |

---

## 1. 休息前檢查清單（離開前逐項確認）

- [x] 當前情境的紅/綠燈狀態已記錄（§2 快照表）
- [x] `tasks.md` §6 對應任務狀態已回寫（本次：**M5 收尾完成**——F07-FE 6/6（DBG-007 三項複合缺陷修正）併入 main 39b5a26＋tag v0.4.11；FE 全回歸 **10/10**＋部署驗證通過）
- [x] 工作區已 commit（`git status` 乾淨）；分支已 push
- [x] truth 對齊：techstack v0.3.7；data-spec v0.3.2；dsl v1.5；T-H9 對齊測試（95 綠內）持續把關
- [x] 「下一步」精確到：Google OAuth 生產接線、驗收走查、PM 決策項（§3）
- [x] 若有進行中 Debug：`specs/plan/debug.md` 條目狀態已更新（DBG-001~**014**；DBG-008~014 均結案）
- [ ] **（發版前）`CHANGELOG.md` 已新增本版區段**（§1.1；未填不得發版）

### 1.1 發行說明（Release Notes）規則（PM 2026-10-26；**每次發版都必須標註改了什麼**）

> PM 指示：**「我要你在每次的發行版都要標註這次的發行修改了什麼」**——本節為固定工作規則。

- **唯一來源**：repo 根目錄 **`CHANGELOG.md`**（`## [x.y.z] - YYYY-MM-DD` 區段）。
- **格式**：固定分類 `### 新增 Added`／`### 變更 Changed`／`### 修正 Fixed`／
  `### 移除 Removed`／`### 文件同步 Sync`（無該類可省略）。
- **寫法**：白話（PM／QA 走查看得懂），不寫內部代號；必要時附 `FR-*`／`DBG-*` 供追溯。
- **填入時機**：**發版前**（與 `pubspec.yaml` 版本號一起改）——不可先 tag 再補。
- **自動化**：`tag-on-main.yml`（主徑）與 `release.yml`（後備）在發佈時以
  `body_path: release_notes.md` 把**該版區段**帶入 GitHub Release 說明
  （awk 擷取；**找不到區段** → `::warning::`＋Release 說明為佔位警示，仍會發佈，需事後補）。
- **發版四步**：①`pubspec.yaml` 改版本 ②`CHANGELOG.md` 新增該版區段
  ③PM 本地預覽＋**親口確認**（原則⓪） ④merge `main`＋push（自動建 tag 併四平台發佈）。


## 2. 目前快照（每次休息前更新此表）

| 欄位 | 內容 |
|---|---|
| 更新時間 | **2026-11-26（計算機鍵盤全面改版批——聚焦滑入（僅編輯交易）＋OK／＝雙態＋四頁常駐回歸；已發佈 PWA＝0.5.1-pwa.20261126b）**（PM 迭代需求：①「編輯交易金額跳系統數字鍵盤」→ 計算機改**聚焦滑入／失焦滑出**（新共用元件 `FocusSlideKeypad`＝ClipRect＋AnimatedAlign heightFactor 0↔1＋TextFieldTapRegion）②「50×2 要立刻顯示 100」→ 先做**即時求值顯示**，PM 實測後改回：**金額欄顯示原始運算式、按 ＝ 才收合為結果**（`display()` 退役——與 ＝ 鍵語意衝突）③小算盤最終形態＝**OK／＝雙態按鈕**（版面樣式完全不變：運算式含運算子→顯示「＝」按了求值收合，key `keypad-equals`；純數字→顯示「OK」存檔，key `quick-entry-save` 契約不變）④**預算表單**金額欄同款計算機（原系統鍵盤；`_save` 改 `AmountKeypadEvaluator.evaluate`）。**PM 實測兩缺陷修正（20261126b）**：①「點每個數字小算盤就收合」＝web 環境點聚焦欄位「外」觸發 `onTapOutside` 失焦——`FocusSlideKeypad` 包 **TextFieldTapRegion**（鍵盤點擊不算外部）②「還沒按＝就算出結果」＝即時求值顯示退役（同上）。**PM 再指示**：「編輯交易以外不要離開聚焦移除小算盤」→ **四頁小算盤常駐**（快記手機／確認清單／桌面面板／預算表單；`_amountFocused` 機制移除），聚焦滑入制**僅存編輯交易**。**部署事故與重要教訓**：本機重建連發 **1.17MB 殘缺殼**（無 App 代碼、必白畫面）——根因＝PWA 建置**漏了 `-t lib/main_web_app.dart`**（pm-actions §223 正規指令；預設入口 lib/main.dart＝native dart:io，編 web＝空殼；隔離測試證明 dart2js/-D/優化等級皆無辜）；正確入口重建＝4.2MB 完整版。**已發佈 gh-pages＝20261126a（bc4aba1）→ b（38a1f7e）→ c（40ef69a，預算起始日改計算機輸入）→ d（c64a934，預算表單小算盤聚焦滑入制）→ e（ade0cdc＝20261127a，壓住小算盤向下滑＝只收小算盤不關視窗）→ f（e2e7e48＝20261127b，確認清單＋快速記帳小算盤常駐＋可下滑暫收）→ g（ab2298e＝20261127c，兩頁改判**比照編輯交易＝純聚焦滑入制**）**＋本機 8123 同步＋worktree `/private/tmp/ledger_sync-pwa-deploy-20261125`（deploy branch 慣例：commit 後 push HEAD:gh-pages；教訓——rsync --delete 會砍 worktree 的 .git 指標與線上獨有檔，須 --exclude .nojekyll/.last_build_id 並排除 landing/scan/zxing 維持線上結構；worktree 分支落後遠端時 push 會 non-ff——以 `git commit-tree <tree> -p <遠端HEAD>` 直接建 deploy commit 繞過）。測試：**298 全綠**（＋3 雙態測試；budget_form 測試改計算機輸入＋常駐鍵盤下 `ensureVisible` 捲至儲存／刪除鈕——測試視窗 600 高被常駐鍵盤擠出視區，真機 844 不受影響）＋analyze 0。**FE 整合測試暫停中之順手修復**：f02 綁定「金額欄下方顯示常駐計算機鍵盤」→「金額欄聚焦後顯示計算機鍵盤」＋移除既有壞步驟 `keypad-＝`（＝ 鍵 2026-10-24 已移除）＋`金額欄顯示 {value}` 改比對即時求值結果、f03 `review-save`（不存在）→`quick-entry-save`＋聚焦、specs/plan/tests/frontend feature 來源檔同步、dsl v1.24 鍵契約更新；f03 FR-S5 情境與 `review-cat/account-*` chip keys 過時（PM 2026-11-22 改版遺留）——待 FE 恢復另案改寫。**下一步**：PM 手機／桌面驗收新計算機互動（編輯交易＋預算為本批重點）；驗收後 source 走 commit＋MR 流程。**✅ PM 驗收 OK（2026-11-27）→ 已 commit＝fea73be 於新分支 `feat/keypad-focus-slide`（18 檔＋1770/−886，已推 origin）——**MR 待建立**：github.com/hung214/ledger_sync/compare/feature/ios-pwa...feat/keypad-focus-slide（base=feature/ios-pwa；gh CLI 未裝，PM 開連結按 Create pull request）。合併後本地切回 feature/ios-pwa。****（前一快照：）2026-11-26（T90 自適應掃描頻率＋iPhone 返回快速恢復＋QR 取景引導＋紀錄補全——feature/ios-pwa）**（PM 需求：①「辨識速度有辦法每秒 5–10 幀？」②「確認清單退回後鏡頭正常了，但要再等約一秒才顯示」③「忘記寫的工作內容記錄在 session」④「沒加入分支的檔案原因是什麼？」。**T90a 自適應掃描頻率**（已實作）：掃描迴圈改自排程（`_startScanLoop`/`_loopDelay`）——上一 tick ≤80ms（原生偵測路徑＝iPhone/桌面）→ **100ms＝10 fps**；≤120ms → 200ms＝5 fps；後備解碼重（紅米 RGBA 深掃）→ 1000ms 保護主執行緒；確認清單開啟中 400ms 慢輪詢（紅米要 5–10fps 需解碼出主執行緒＝Web Worker/zxing-wasm 另案）。**T90b iPhone 返回快速恢復**（已實作）：`restartPreviewFresh` 改**串流重用**——確認清單期間串流仍活著 → 直接綁到全新 video 元素/槽（跳過停軌＋600ms 釋放＋重新 getUserMedia≈1 秒＝**零黑屏瞬換**）；串流死才走重取（videoWidth==0 兜底 _openOn）。**T90c QR 取景引導**（已實作）：電子發票模式、無偵測框時顯示「把左右 QR 條碼放進框內」固定取景引導框。**PM 動作補記**（原未記錄）：①將 T89 系列程式 **cherry-pick 至 feature/ios-pwa**（f5577c0「0.5.1-pwa.20261125s 調整鏡頭回復與辨識速度」＋08cb05e「PICK 0.5.1-pwa.20261125s」——含程式＋文件＋html5qrcode 檔案退役）②建標籤：**優化辨識速度**＝b8a2830（T89b）、**鏡頭功能完整**＝4e74e21、**鏡頭辨識完成－需要小調整**＝fb55b4c（T89c）③**自行部署 gh-pages＝0.5.1-pwa.20261125q**（取代先前 s——CDN 已驗證線上＝q）④澄清：q/r/s 為 **gh-pages 部署版本戳**（非 git tag）。**測試補全**：ios-pwa 缺 T89 RGBA 直入單元測試（pick 未含）→ 已補。**未納入分支的檔案說明**（皆為 2026-11-21「LOGO/ICON 暫套＋相機診斷批」依 PM 指示「工作區 WIP 不 commit」保留）：README／pbxproj（圖示草稿 A 暫套）／MainFlutterWindow.swift（**DBG-017 修復**已 ✅ 結案——**已收編** 2026-11-26 PM 核准）／debug.md（DBG-017/018 記錄——**已收編**）／techstack.md（v0.3.13 圖示——**已收編**）／manifest.json（僅檔尾換行）；未追蹤＝.omo/.playwright-mcp（工具狀態，建議 gitignore）／BUILD_CLEANUP＋CROSS_PLATFORM_REFACTOR_GUIDE＋LOCAL_DEPLOY 三份指南（待 PM 決定）／jpg＋logo-drafts（LOGO 素材評估中）／ledger_backup_*.db（**真實資料備份——勿進 git**）／tool/*.ignore（廢棄草稿）／web/zxing（**T85 已退役 html5-qrcode 的殘留資產——建議刪除**）。✓295 全綠＋analyze 0。**T90d/e/f**（PM 回饋三點）：①「辨識時慢時快」＝**入單即清累積窗**（已入單的碼留窗內會擋下一張 2–3 秒＝掃完一張後下一張變慢的主因）＋新左碼清孤兒右碼（防跨發票混碼——parseOfficial 未驗證配對，右碼格式驗證待真實樣本另案）②「確認清單沒按 OK 直接退出→變連續掃描」＝自動進確認清單條件改「有新增就觸發」（原「prev 空」——按返回後草稿非空＝單張模式退化；按返回未存項目保留）③「iPhone 沒有提示」＝提示只在「只掃到右碼」部分狀態出現；iPhone 原生引擎＋10fps 一幀抓雙碼→即時入單無部分狀態（逐碼回饋＝teal 偵測框）。✓E2E 全流程。工作分支＝feature/ios-pwa。**PM 決策 2026-11-26**：「掃描發票帶入商家名稱」**先不做**（QR 內容無商家名稱、僅賣方統編——draft 已存 sellerTaxId；可行方案 A 統編記憶對應／B 政府開放資料查詢（公司登記才查得到）／C OCR 抬頭，留待日後）。（**2026-11-25 以前的每日快照**：已遷出 → `session-archive.md`） |
| 階段 | **M1~M7＋M5 全數完成**，並已完成**雲端生產接線**（GoogleDriveAdapter／降級／main() 注入／三平台連網權限——v0.4.12）。**上架僅剩外部相依（PM 憑證／帳號）＋驗收走查單**：見 **`specs/plan/pm-actions.md`**（唯一 PM 入口文件） |
| 當前分支 | **feat/keypad-focus-slide**（fea73be 已推 origin——計算機改版批 18 檔；**MR 待合併**：compare/feature/ios-pwa...feat/keypad-focus-slide；合併後切回 feature/ios-pwa）。來源：**feature/ios-pwa**（origin 至 `2d7f12a`＝fake controller setFocusPoint 補齊；**main 亦同步至 f1f79b2＝v0.5.0+2 發版**；**tag v0.5.0 已推**）。另有 `pwa-acc**main 亦同步至 f1f79b2＝v0.5.0+2 發版**；**tag v0.5.0 已推**）。另有 `pwa-accumulate`（PWA 穩定線：8596c27 基底＋T52 明細修改＋累積合併＋看門狗）與 `camera-improvements`（鏡頭實驗凍結分支）。歷史：自 fix/quick-entry-v3-ledger-display `e1e90ff` 切出；已推 origin，11 筆提交至 `70bd21d`｜先前：fix/quick-entry-v3-ledger-display（e1e90ff 已推）；本地 main 仍領先 origin/main 未推｜先前：**main**（cadd29a 已 push）；本地分支已清；遠端僅 main／session/handoff |＝發票左碼聰明定位 2026-11-20；**11-21 批（相機切換＋LOGO）工作區 WIP 未 commit**）。歷史：自 fix/quick-entry-v3-ledger-display `e1e90ff` 切出；已推 origin，11 筆提交至 `70bd21d`｜先前：fix/quick-entry-v3-ledger-display（e1e90ff 已推）；本地 main 仍領先 origin/main 未推｜先前：**main**（cadd29a 已 push）；本地分支已清；遠端僅 main／session/handoff |
| 當前任務 | **（2026-11-24）0.5.0 正式發版完成**——下一步：①**PM 走發版驗收清單**（release-0.5.0-checklist.md）②**T45 PWA 黑畫面離線診斷**（headless Chrome；camera-improvements 分支）③**Big5 品名亂碼**（需對照表）④**T21 OCR 文字框 PWA 端**（photo preview 已做、PWA 未部署——屬 camera 凍結範圍）⑤**zxing-wasm 接線**（檔案已下載 web/zxing/ 未接線——camera 凍結範圍）。先前：**（2026-11-21）相機切換診斷批 1121g＋LOGO/ICON 暫套＋子類別帶入**：等 PM 回報 1121g 面板文字（切換失效定位）＋黑畫面/掃描解碼驗收＋LOGO 定稿；工作區 WIP 待 commit。先前：**11-17~11-20 批**（F13 引導頁／F14 PWA 相機掃描／F15 Argon2id／F16 UI 對照／SP-2b 原生相機＋雙碼配對／匯入修復＋資料版本戳）；**M8/F11 全數完成**（v0.4.15）：帳戶管理/分類管理（主子階層＋雙層拖曳）/外觀主題（持久化）＋**分類體系 v2**（主類別集 PM 定稿：支出 14＋收入 2）＋**常用類別區**（MRU 10 常駐快記選擇器最上方）＋快記選擇器階層化。後續：①UI-P3 預算→P4 快記→P5 掃描·信用卡·設定 ②測試分流（頁面情境遷 widget test） ③`pm-actions.md`（PM 憑證/帳號/決策——§9 新增分類決策記錄） |
| 缺口（PM 走查 2026-10-22 發現） | ①**帳戶設定頁**（名稱/類型/**是否合併計算**）未實作→ FR-A7 新增（SPEC/SDD/BDD/tasks 已補）②**分類設定頁**未實作（雛型 `ui/09-category-settings.html` 早已存在）→ FR-B1 補 ③**外觀主題（明亮/暗色/跟隨系統）**無 App 內切換（FR-O1 P0，設定雛型有外觀段）→ 已納入 F11 ④**`CategoryRow`/`insertCategory` 未帶 `icon/color/sort_order/deleted_at`**（V1 DDL 與 data-spec.dbml 早已有——truth 未對齊，分類管理做不出來之根因）→ T-F11-BE 修 ⑤**UI 未對照雛型**（例：總覽/明細版面）→ UI-P1/P2 已修，P3~P6 待續 |
| ⚠️ 環境重大變化 | ~~Xcode 消失~~ **已恢復**（2026-10-24 重裝＋授權接受——本機四平台建置正常；2026-11-16 本批 macOS Release 驗證 53.4MB ✓）。原記錄：**Xcode 曾從本機消失**（/Applications 無、Spotlight 無、垃圾桶無——疑似磁碟告急時被刪，佔 30-40GB）。影響：本機無法 build macOS／跑 macOS integration test／部署驗證；**unit/widget test 不受影響（純 Dart）；CI 雲端建置不受影響（發佈照常）**。需本機 macOS 驗證時須重裝 Xcode |
| 環境筆記（v0.4.18 追加） | ⑨**測試 viewport 折疊線**：長頁內容超出預設 600px 測試視窗時，`find` 預設略過視口外元素（offstage 語意）——放大 `tester.view.physicalSize`（如 1080×2400）＋reset ⑩**平面分類清單首位≠主類別**（sort_order NULL 排序在後）——下拉預設值須取 `parentId==null` 首項 ⑶python heredoc 產生 Dart 字串插值時 `\$` 會變字面——寫 `$` 即可 |
| 環境筆記（2026-10-26 追加） | ㉕**`open` 不會重啟已在執行的 App**——只會把既有實例帶到前景，因此「建置完成＋open」後**驗收看到的仍是舊版**（本輪踩到：PID 26583 為舊版）。正確流程＝`kill <pid>`（或 `osascript -e 'tell application "ledger_sync" to quit'`）→ 確認 `pgrep` 無殘留 → `open`。驗證「是否為新版」看 `Contents/Frameworks/App.framework/Versions/A/App` 的 mtime（**Dart AOT 在 App.framework**；執行檔 `Contents/MacOS/ledger_sync` 為原生 runner，改 Dart 時 mtime 不變）。 ㉗**`System Events` 的 `click at` 會點到「當時最前景」的 App**——助理自動化前必須先確認目標 App 在最前景（`set frontmost to true` 有時回 -10006；`open` 對執行中的 App 只是帶到前景，**若使用者正在用別的 App 可能搶不回來**）→ 使用者正在操作電腦時**不要**盲點座標，以免干擾其瀏覽/輸入。㉖輔助取用權限會**時開時關**（同一天內曾可用、又被系統收回 -10006／-1719）；螢幕休眠時 System Events 回報 0 windows、`screencapture` 全黑——自動驗證前先確認螢幕喚醒。 |
| 環境筆記（v0.4.25 追加） | ㉑**切片刪除程式碼時，用「下一個 `  /// `」定位會越界**（跨 class 刪到別區）——刪大段程式碼請用**成對唯一錨點**或 edit 工具 ㉒**Dart 字串內 record 欄位 `$1/$2` 在 python heredoc 會被吃掉**——先寫成 `\$` 再修、或改用暫存變數 ㉓明細「月份制」改 `_periodRange()` 簽名時，呼叫端（搜尋/匯出標籤/_hasFilter）要一併改 ㉔**截圖核對**：`screencapture -x` 需「螢幕錄製」權限（PM 已開）——**改完 UI 先截圖自己看再交付** |
| ⏸️ FE 測試暫停（PM 2026-10-24） | **`integration_test/features/*` 一律不跑**（PM：很多東西還不正確，等指示再恢復）。期間護欄＝`flutter test`（test/：unit＋widget，含 `test/presentation/*` 頁面情境）＋`dart analyze`。**檔案保留**（analyze 維持 0；待恢復時再逐檔重跑並對齊當時 UI）。CI 只跑 `flutter test`，不受影響。 |
| 環境筆記（v0.4.24／快記 v3 追加） | ⑱**Xcode 授權閘**：Xcode 版本升級（26.6→27.1）後須重新 `sudo xcodebuild -license accept`；未同意時 `xcrun` 被鎖→**`git`／`flutter`／`cocoapods` 全數不能用**（暫時繞道：`DEVELOPER_DIR=/Library/Developer/CommandLineTools` 可跑 analyze/unit，**不能** build macOS）⑲**長清單／捲動區元素**：`ListView` 懶載→未建出的項 `find`/`tap` 皆落空——改 `SingleChildScrollView+Column`（全建出）＋入口置**頂部**⑳**受控欄位 ↔ state 同步**：外部寫入 state（記住上次帶入金額/商家）時，本地 `TextEditingController` 須以 `ref.listen` 同步，否則畫面不更新 |
| 環境筆記（v0.4.20/21 追加） | ⑮**Riverpod `Provider` 快取**：任何 CRUD 後除 `setState` 外必須 `ref.invalidate(衍生 provider)`——否則他頁停留舊值（分類設定→快記/預算/明細不連動之根因 DBG-009）⑯**捲動區外元素測試**：emoji chips 於 `SingleChildScrollView` 內，最後一個 chip 需 `ensureVisible` 再 tap（否則 tap 落空、靜默不改值）⑰**AppLockController 建構子 `pin` 可選**＋`hasPin`（無 PIN 裝置：不寫 hash；需 PIN 關卡依 hasPin 決定，DBG-008） |
| 環境筆記（v0.4.19 追加） | ⑪**測試直接 pump 頁面**時 `DateFormat(locale)` 會炸（locale 未初始化）——自製星期對照表繞過 ⑫**save 後 FR-Y11 afterSave 讀 syncCoordinatorProvider**——widget test 必須 override（`SyncCoordinator(db, InMemoryCloudAdapter(), deviceId)`），否則 UnimplementedError 中斷閉包 ⑬**SnackBar 於 pumpAndSettle 會被快進自動關閉**——測試改 `pump(); pump(300ms)` 定點斷言 ⑭**桌面殼 keys 契約**：`nav-{label}`（雙殼共用）/`fab-quick-entry`（工具列鈕）——f02/f08 harness 相依 |
| 下輪起點（TODOLIST） | ⓪**相機切換定位（等 PM）**：PM 回報 1121g 面板整行文字（`幀 N · … · facing=…｜切換結果`）→ 對策表：`✓exact→user` 但畫面沒變＝iOS session 黏住→**整頁重載式切換**；`✗NotReadableError`→加長釋放等待；面板無 `facing=`→舊版快取→清網站資料 ①黑畫面/掃描解碼 PM 驗收 ②**LOGO/ICON 定稿**（三版草稿等 PM 選；定稿後正式換裝＋工作區一併 commit）③**工作區 commit**（11-21 批 56 檔 WIP——相機批＋LOGO 資產＋新測試）④v0.5.0 發版（驗收清單/Release Notes 已備 `b0589f2`/`971d3ba`）。先前：⓪**PWA 收尾（等 PM）**：①**GitHub Pages 設定**（pm-actions §15——Settings→Pages→gh-pages；2 分鐘）→ 我做 P7.5 上線驗證 ②**OAuth client id＋origin**（§14）→ 我做 P5.5 E2E（web↔Drive 真實往返）③**AndroMoney CSV**（I1）→ 匯入批 ④**發版 0.5.0** 親口確認（§6.3）。程式面已完成：P3 資料層／P4 附件／P5 雲端層／P6 降級／P8 UI／P7.1-3 部署（tasks §6.0b）。先前：⓪**最近刪除·永久刪除**（PM 2026-10-24 需求增補）**已完成待驗收**——單筆/清空全部＋二次確認＋原型 `12-recent-deletions.html`＋DEMO「12 最近刪除」＋測試 8 綠；①**重建 .app**（含統計 v2＋永久刪除＋DEMO 本批）→ PM 驗收（統計頁/明細月份制/交易編輯/快記 v4/資料管理範圍勾選/**最近刪除：還原＋永久刪除**）②UI_DEMO：quick_entry_demo 日期列＋ledger_demo 標籤細節（次要）②FE 測試**暫停中**——恢復時：session「⏸️ FE 測試暫停」段＋dsl §4.6-4.8 keys 對照，**逐檔**重跑並對齊（f02 拆分情境已移除、f09 加範圍步驟、f01 聚焦斷言移至 widget test）③「明細→編輯」**拆分 UX 待 PM 回饋**（已做：2 子項分類/金額→executeSplit＋原交易軟刪除）④發佈：PM 確認後合併 main＋push tag ⑤UI-P5 掃描·信用卡·設定（02/06/07 對照）⑥PM 決策：首次啟動引導頁（file_picker）／NFR-03 ⑦總覽頁最近交易之圖示圓（01 雛型；明細已做） |**快記 v3 待 PM 預覽確認**（本機建置＋實機；雛型 03/10/08）→ 確認後發版 ②後續：UI-P5 掃描·信用卡·設定 ③**等 PM 決定是否發 v0.4.21**（DBG-009 修復）（DBG-009 修復；照「預覽→PM 確認→發佈」流程）②**UI-P5 掃描·信用卡·設定**（02/06/07 雛型對照——交易列 emoji 圖示圓也對齊 DEMO）③測試分流：頁面情境 widget test 化（Xcode 缺——唯一護欄）④PM 實機試用 v0.4.20/0.4.21 回饋 ⑤PM 決策：首次啟動引導頁（file_picker）／NFR-03 ⑥未結待辦：Ledger TxTile 之 emoji 圖示圓 |
| 紅綠燈狀態 | `dart analyze` 0＋**unit/widget 273 全綠**（2026-11-21 批後：＋切換 diagInfo 契約更新＋scan_page_controls_test＋quick_entry_category_prefill_test；FE 暫停維持；web 驗證＝線上 bundle 特徵碼。歷史：168 全綠（162＋Drive seam 6；web 驗證＝headless Chrome 對 build/web——**flutter test --platform chrome 不供 assets 不可用**）（歷史：unit/widget 143 全綠（FE 暫停）——**新增** `category_display_test` 3（圖示規則：子類別空字串回退主類別／非庫內→🏷️）；——**新增** quick_entry_layout_test 4（手機版面契約：無三欄格／OK 跨兩格／帳戶｜分類同列＋順序＋金額右對齊／轉帳來源｜目標同列）————**新增** purge_tombstone_use_case_test 4（實體刪除/oplog 保留/冪等/未刪除 StateError/清空全部）＋recent_deletions_page_test 4（清單/單筆永久刪除/取消/清空全部）——ledger_tile_test 4、ledger_page_test（月份列）、amount_keypad_test（無＝/版面）、data_management_wipe_test（範圍步驟）、quick_entry_ui_test（彈窗/備註/記憶/autofocus）＋BE F08 6 情境＋**FE 全回歸 11/11 綠**（新增 `test/presentation/data_management_wipe_test`＋`category_settings_page_test` 子分類編輯/連動）＋**F08-BE 6 情境綠**（新增 PIN 未設定/已設定判定）；FE：f01~f10 全綠＋F11-FE 11/11（v0.4.16 前測得——本機無 Xcode 不再重跑）；**v0.4.20 tag 已建**（CI 四平台） |
| 工作區 | **計算機改版批已 commit**（fea73be 於 feat/keypad-focus-slide——18 檔：lib 六畫面＋keypad 元件＋測試五檔＋FE 整合測試修復＋specs/dsl/session 同步；**MR 待 PM 合併**）。**PM 自己的修改未 commit**（README/Xcode/manifest 等——AI 不動，PM 自行處理）。**gh-pages 已推＝0.5.1-pwa.20261127c（ab2298e）＝線上與本機 8123 皆此版**。歷史：WIP 未 commit（2026-11-21 批：相機切換/診斷＋LOGO/ICON 等） |
| truth 對齊 | techstack **v0.3.13**（2026-11-21：LOGO/ICON 素材授權＋相機批登記；歷史：v0.3.11（PWA 批登記：web 1.1.2／http 1.6.0／archive 4.7.1；**§6 SP-8 PWA Spike 結案**）（歷史：techstack v0.3.7（**待追加 googleapis／googleapis_auth／google_sign_in——需 PM 簽核**）；dsl v1.5；data-spec v0.3.2；debug.md DBG-001~007 結案；新增 `pm-actions.md` v0.1 |
| 環境筆記 | 延續上輪全部。新增（v0.4.12）：①**Flutter macOS App 預設沙箱**——資料在 `~/Library/Containers/<bundle-id>/Data/Documents/`（非 `~/Documents`）；**沙箱須 `com.apple.security.network.client` 才能連外**（原缺→Release 連不出去）②**Android release 需在 main manifest 加 `INTERNET`**（Flutter 範本只在 debug/profile 內建）——「程式對但連不出去」首查清單見 pm-actions §1.4③`_tapUntil` 穩健 tap（macOS 遮擋節流；未生效才真實等待）④harness 每個 Scenario 都要 `_ensureApp`⑤`Uuid().v7()` 可 const |
| 環境筆記（v0.4.16 追加） | ⑥**長 PopupMenu 底部項目點不到**：~85 項選單底部在 LazyListView 未建/超出畫面——動作入口（＋新增分類）放**選單頂部** ⑦**BE 斷言同層化**：播種兩層分類後「首位/次位」「sort_order 連續」須按 parentId 群組判斷（平面清單會誤判） ⑧**種子名 vs 測試名碰撞**：播種後測試情境改用非種子名（早餐→甜點等）；服務加同層重名拒絕 |
| 環境筆記（本輪新增） | ①**ReorderableListView 自動化拖曳**：單次 `dragFrom` 會早一步落下——必須**分段 move**（startGesture→小步 move×8→up）＋**重試**（拖曳中列表即時重排，預估距離會漂移；每次重試多補償 24px＋early-exit「已在目標前」檢查）②**find.text 全樹誤中**：主殼 IndexedStack 其他分頁（明細交易列）文字會多算——常用區斷言改專屬 key（`recent-cat-{name}`）③**選單顯示勿用文字 hack**：子分類縮排用結構（Padding+Icon）而非 '　↳ ' 前綴——否則 find.text 精確比對落空 ④FE harness 逐檔改名時**兩份都要**（test/bdd/＋integration_test/features/——本輪漏後者導致 f05 紅）⑤句型順序：長句型先註冊（`餘額 X 且不計入` 搶配 `餘額 X`） |
| 阻塞／待決 | ⓪**相機切換定位（等 PM 回報 1121g 面板文字）＋LOGO/ICON 定稿（PM）**①**Google 憑證（PM）**——最高優先；DriveApi／OAuth 實作待其到位②商店帳號＋簽章（Apple/Google）③gh 未安裝（Release 下載驗證）④acceptance F03 測資字串修正待 PM 複核⑤SP-1 SQLCipher⑥SP-2b 行動相機（F03 走查前）⑦SP-4 Argon2id（PIN FNV）⑧多幣別 900／notify_enabled=off 語意⑨NFR-03 定義⑩首次啟動引導頁決策⑪深色模式 PM 走查 |

## 3. 下一步（唯一入口：`specs/plan/pm-actions.md`）

### 3.1 已完成（追溯；F07-FE 回頭／DBG-007）
0. ✅ harness 導航補步（`app-settings`→`settings-sync` Hub 兩層）。
1. ✅ S1 卡點＝**macOS 遮擋節流**（非 rebuild 競爭）——證據：聚焦除錯測試顯示按鈕在樹上、rect 正確、`hitTestOnBinding` **空路徑**；解法 `_tapUntil`。
2. ✅ **S4 還原／S5 異帳號／S6 衝突檢視全數補齊並驗證**——DBG-007 三項複合缺陷（還原缺登入步／S5 缺導航／S6 缺 `_ensureApp`）。
3. ✅ F07-FE 6/6 → FE 全回歸 10/10 → 部署驗證 → merge 39b5a26 → tag v0.4.11。
4. ✅ 雲端生產接線＋三平台連網權限 → merge 51cbbcb → tag v0.4.12。

### 3.2 下一步（依 `pm-actions.md`）
1. **PM：啟動 Google OAuth 送審**（pm-actions §1.1）——等待最久＝關鍵路徑。
2. **憑證到位後（開發）**：`DriveApi` 實作（googleapis Drive v3）＋OAuth 登入（google_sign_in／loopback）＋套件追加（techstack 需 PM 簽核）＋真機端對端驗證。
3. **上架工程**：簽章（Apple notarization／Android keystore）＋商店 listing＋隱私政策網頁（pm-actions §2）。
4. **驗收走查簽核**：F08/F09 簽核區＋四平台實機＋深色模式（pm-actions §5）。
5. **待 PM 決策**（pm-actions §4）：首次啟動引導頁／NFR-03／F03 測資複核／語意項。

### 通用 harness/UI 教訓（跨功能累積，持續生效）
- **macOS 遮擋節流 → 穩健 tap**：視窗非前景/被遮擋時 display link 暫停，render tree 陳舊 → 裸 `tap` 落空（症狀：spinner 永動、`pumpAndSettle` 逾時）。用 `_tapUntil`（tap→pump→未生效才真實等待重試，正常零延遲）——**建議抽為共用 helper**。
- **每個 Scenario 的 Given/When 都要 `_ensureApp`**：否則 container/樹為前一情境殘留（F07 S5/S6 曾因此 0 widgets）。
- **讀規格看「兩步互動」**：還原（S7.4）與連結皆「導向登入→同意授權」兩步；實作勿一步吞。
- **新 harness 一律 override `syncCoordinatorProvider`**（F07-BE afterSave 接線——`ref.read(autoSyncProvider)` 建構即拋，不分 sync.mode）。
- CreditCardPage 開頁副作用：initState postFrameCallback 觸發結帳檢查（FR-C3 sync 點）——勿在 build 中 ref.read/invalidate。
- 推入路由後主殼 offstage：harness 跨頁斷言前先 `navigator.maybePop()`。
- 金額輸入千分位：parse 須 `replaceAll(',', '')`。
- dsl 變體先於 base 註冊（lazy 前綴碰撞）；同名捕獲群禁用（{n} 出現兩次→後者改 {last}）。
- 測試勿對 UUIDv7 字典序順序斷言（DBG-005）；flaky 排查先落盤再循環重跑。
- 「flutter test integration_test」多檔併跑不可行（macOS 多 app instance 掛 debug connection）——**逐檔跑**。

## 4. 恢復工作 SOP（下次開工照此執行）

1. 讀本檔「目前快照」與「下一步」。
2. `git status` + `git branch --show-current` 確認分支與工作區。
3. 跑 `dart analyze`（注意環境筆記）與 `flutter test` 確認燈號與快照一致。
4. 不一致 → 以測試實際狀態為準並修正本檔，再繼續。
5. 從「下一步」第 1 項繼續；完成一個情境即 commit 一次。

## 5. 歷程記錄（append-only，新在上面）

| 日期 | 摘要 | 分支 | 狀態 |
|---|---|---|---|
| ～2026-11-25 | （歷史紀錄已遷出 → **`session-archive.md`**；本表僅保留近兩日） | — | — |
