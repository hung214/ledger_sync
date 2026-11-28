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
| 更新時間 | **2026-11-27（計算機批收尾＋CI 根因修復——fix/ui-text-wrap）**（**MR #2（e5d0f8c）＋MR #3（fix/ui-text-wrap，2732568）均已合併進 feature/ios-pwa**——分支已清理（本地＋遠端）。**T91 順序掃描＋ROI 已合併**（feat/scan-sequential-roi b576c2c → de788db，PM 指示本地合併；分支已清理；**教訓：release JS 的中文＝\\uXXXX 轉義**——驗證 build 內容要用轉義形式，Dart 識別字會被壞碼）。**PWA 發佈＝0.5.1-pwa.20261127i**（gh-pages d106c33，CDN 驗證 ✓；h＝per-chip 重構前 build——i 才含 chips 寬度卡死修復上手機）＋**介紹頁上線**（web/landing，gh-pages 3940314；截圖含發票號/金額之公開性提醒 PM）。**CI 修復**：鎖 Flutter 3.47.7＋analyze --no-fatal-infos＋test --reporter github（失敗測試名進 annotation）。**CI 紅測根因**（「明細：多帳戶 chips 可水平滑動」本地綠/CI ubuntu 紅）：chips **整列 KeyedSubtree** 重建（settle tick）會**重置捲動位置**並與測試捲動賽跑→改**每顆 chip 各包 KeyedSubtree**（key 帶標籤內容＋settle tick）——記帳後標籤變→單顆重測寬（修「寬度卡死要改名才恢復」）、開頁 600ms 字型載入→以已載入字型重排（web 字型競態自癒）、**Scrollable/捲動位置不動**、chip 本體 key `acct-chip-{id}` 契約不變；滑動測試改**確定性斷言**（maxScrollExtent>0＋jumpTo 到底驗最後一顆可達——不依賴跨平台手勢模擬）。同批 commit 0f895a2：商家池分離（distinctMerchants(kind:)＋setMode 清 Sticky）＋總覽三卡渲染後實測堆疊＋快記模式列/chips 直排修正。**本地 302 全綠＋analyze 0**，已 push（c3dbf8b..0f895a2）等 CI；**CI 二輪才綠**——第一輪再爆**另一獨立問題**：merchant_picker_test 遺留未讀取的 `picked` 變數＝**warning 級**（教訓：`--no-fatal-infos` 只放行 info，**warning 仍擋 CI**；本地驗證要用 `flutter analyze --no-fatal-infos` 原樣指令＋grep warning/error 而非只 grep error）→ 移除後 47a3477 **CI 綠燈 ✓**→ **MR #3 已由 PM 合併**（2732568），部署鏈補至 **20261127i**（d106c33）。**追加批**：快記備註右下角**取消／儲存**（PM 2026-11-27 比照編輯交易——**僅手機版** max-width<900 與 main_shell_page 斷點一致、桌面不加；取消＝清金額＋備註、Sticky 帳戶/分類/商家/時間保留；儲存＝同鍵盤 OK＋quickEntrySaveEnabled 禁用判定；key `quick-entry-cancel`／`quick-entry-save-btn` 與鍵盤 `quick-entry-save` 契約分開）——分支 `feat/quick-entry-note-actions`（3701069，3 測試＋全套 314 綠，MR 待 PM）；**部署 20261127j**（gh-pages 3cf8e42，CDN 驗證 ✓——**從 commit 乾淨 worktree build**，工作區有 T91 掃描 WIP（另一工作）不得混入線上 build）。**部署 20261127k**（gh-pages 24d7694，CDN 驗證 ✓）＝**快記按鈕＋T91 同版**——快記分支先 merge feature/ios-pwa（3bf00ba，314 綠）再 build，避免 k 把已上線的快記按鈕退回；快記 MR（feat/quick-entry-note-actions）仍待 PM 合併（合併後內容＝k，無需再部署）。**MR #4 已合併**（7f5be04）。**追加批**：確認清單備註右下**儲存**（PM 2026-11-27——備註聚焦時鍵盤收起，免「完成→重聚焦金額欄→鍵盤 OK」即可存；僅手機版 max-width<900 同快記慣例；`_saveEnabled` 禁用判定；key `review-save-btn`）——分支 `feat/review-note-save`（316 綠，MR 待 PM）。**部署 20261127l**（gh-pages 94528d2，CDN 驗證 ✓）。**worktree 教訓**：`git worktree add <path> <分支名>` 對**已被主樹 checkout 的分支**會 fatal（already used）——要用 `--detach`＋commit SHA。**追加批（桌面版調整，PM 2026-11-27）**：①**金額欄實體鍵盤輸入**——桌面（≥900）編輯交易＋預算表單金額欄開放鍵盤輸入（過濾數字/運算子；手機維持唯讀）；**ASCII 運算子正規化**＝`AmountKeypadEvaluator.normalizeHardwareOperators`（`+ - * /`→`＋ － × ÷`——評估器僅認全寬，最初直接放行 ASCII 會讓運算式無效＝OK 禁用，測試 50\*3 卡 120 才抓到）；桌面輸入後鍵盤滑入蓋住底部儲存鈕——存檔走鍵盤 ＝（keypad-equals 收合）→OK（quick-entry-save）②**桌面快記面板與手機一致**：補**繳卡費** segment（有信用卡才顯示；目標＝信用卡下拉、分類/商家不適用；存檔＝repayment）＋`showSelectedIcon:false`（移除勾選示意 ICON）——分支 `feat/desktop-input-and-repay`（318 綠，MR 待 PM）。**部署 20261127m**（gh-pages e35a722，CDN 驗證 ✓）。**追加修正（PM 2026-11-27 二輪）**：①桌面模式列**繳卡費被擠成直行**→文字 maxLines:1/softWrap:false＋收緊內距（visualDensity horizontal -4＋padding 6＋字級 13）＝按鈕以內容寬度排列不換行 ②預算**週期起始日**桌面（≥900）亦開放鍵盤輸入（僅數字；_save clamp 1~28）——commit 5a16dab（318 綠）。**部署 20261127n**（gh-pages 1866c55）。**追加批（2026-11-28）**：①**預算頁月份選擇**（PM：預算頁顯示當月→要可選不同月份）——月份列 ◀ 2026年11月 ▶（預設當月、點標籤回當月）；語意＝檢視 M 月＝M 月 startDay 起算的週期（新 `BudgetPeriodService.periodOfStartMonth`；與 periodOf「含 now」並存）；BudgetEvaluator 用量/達標率支援 month 參數；_PeriodInfo elapsed/remaining clamp——過去月＝全期、未來月＝0、當月數值不變；測試：當月 100→◀ 上月 50→標籤回當月 ②**快記備註區取消按鈕移除**（PM——儲存保留；放棄草稿用鍵盤 C／⌫；controller cancelEntry 退役）——分支 `feat/budget-month-select`（315 綠；**教訓：budget_page 月份列編輯曾造成卡片重複渲染**——分類磚斷言 budget-total-card found 2 抓到，刪重複後恢復）。**部署 20261128a**（gh-pages 7364fe6，CDN 驗證 ✓——版本戳＋月份列在線上、取消鈕 key 已消失）。**⚠️ 部署退回事故與修正**：a 版從 feat/budget-month-select（base＝MR #6 合併前）build——**線上短暫退回桌面功能**（MR #6 已合併 c820a74）；修正＝origin/feature/ios-pwa 併入分支（後改 **rebase**——分支 history 重寫需 `push --force-with-lease`）→ **部署 20261128b**（gh-pages 8300ccf）＝**月份選擇＋快記取消移除＋桌面調整（MR #6）同版**，CDN 內容指標 ✓（版本戳待快取過期）。**教訓**：部署前必確認分支 base 含**所有已上線功能**（比對前一版部署來源）；有並行 MR 合併時先 fetch 再開工。**MR #5（確認清單備註儲存）＋#6（桌面調整）＋#7（預算月份選擇）均已合併**（93a1ae4）——三分支已清理（本地＋遠端）；合併樹＝已上線 b 版內容，**無需再部署**。工作區現有另一工作流 WIP（budget_alert_service/budget_service/category_picker_dialog/quick_date_time_picker 等）不触碰。**無用代碼清掃批 A（PM 2026-11-28）**——分支 `feat/cleanup-dead-code`（3a4ee07，321 綠）：刪 `lib/main_web_spike.dart`（P1 Spike 入口）＋`lib/main_web.dart`（P3.5 驗證入口）——皆無引用（**教訓：檔案級死碼 analyzer 不報**，需人工盤點）＋工作區移除 web/zxing（T85 殘留）/scan/.qodo/tool/scratch_check.dart.ignore；demo 頁保留（PM 未決退役）。**部署 20261128c**（gh-pages 0778268，CDN 驗證 ✓）。**待 PM 決定**：demo 頁去留；批 B（web_camera_scan 50KB 拆檔）與批 C（native/web 共用 UI 抽取）待指示。**未決**：repo 私有化方案（A=GitHub Pro／C=Cloudflare Pages）等 PM 選擇。工作區保留 PM WIP（README/pbxproj/web/manifest.json/logo-drafts 等）不 commit。**（前一快照：）****2026-11-26（計算機鍵盤全面改版批——聚焦滑入（僅編輯交易）＋OK／＝雙態＋四頁常駐回歸；已發佈 PWA＝0.5.1-pwa.20261126b）**（PM 迭代需求：①「編輯交易金額跳系統數字鍵盤」→ 計算機改**聚焦滑入／失焦滑出**（新共用元件 `FocusSlideKeypad`＝ClipRect＋AnimatedAlign heightFactor 0↔1＋TextFieldTapRegion）②「50×2 要立刻顯示 100」→ 先做**即時求值顯示**，PM 實測後改回：**金額欄顯示原始運算式、按 ＝ 才收合為結果**（`display()` 退役——與 ＝ 鍵語意衝突）③小算盤最終形態＝**OK／＝雙態按鈕**（版面樣式完全不變：運算式含運算子→顯示「＝」按了求值收合，key `keypad-equals`；純數字→顯示「OK」存檔，key `quick-entry-save` 契約不變）④**預算表單**金額欄同款計算機（原系統鍵盤；`_save` 改 `AmountKeypadEvaluator.evaluate`）。**PM 實測兩缺陷修正（20261126b）**：①「點每個數字小算盤就收合」＝web 環境點聚焦欄位「外」觸發 `onTapOutside` 失焦——`FocusSlideKeypad` 包 **TextFieldTapRegion**（鍵盤點擊不算外部）②「還沒按＝就算出結果」＝即時求值顯示退役（同上）。**PM 再指示**：「編輯交易以外不要離開聚焦移除小算盤」→ **四頁小算盤常駐**（快記手機／確認清單／桌面面板／預算表單；`_amountFocused` 機制移除），聚焦滑入制**僅存編輯交易**。**部署事故與重要教訓**：本機重建連發 **1.17MB 殘缺殼**（無 App 代碼、必白畫面）——根因＝PWA 建置**漏了 `-t lib/main_web_app.dart`**（pm-actions §223 正規指令；預設入口 lib/main.dart＝native dart:io，編 web＝空殼；隔離測試證明 dart2js/-D/優化等級皆無辜）；正確入口重建＝4.2MB 完整版。**已發佈 gh-pages＝20261126a（bc4aba1）→ b（38a1f7e）→ c（40ef69a，預算起始日改計算機輸入）→ d（c64a934，預算表單小算盤聚焦滑入制）→ e（ade0cdc＝20261127a，壓住小算盤向下滑＝只收小算盤不關視窗）→ f（e2e7e48＝20261127b，確認清單＋快速記帳小算盤常駐＋可下滑暫收）→ g（ab2298e＝20261127c，兩頁改判**比照編輯交易＝純聚焦滑入制**）→ h（15d01bb＝20261127d，**手機版文字直排修正**——快記模式列 showSelectedIcon:false＋明細 chips maxLines/showCheckmark:false）→ i（700e523＝20261127e，總覽「負債」標籤）→ j（44f3b8a＝20261127f，商家池分開＋三卡 TextPainter 堆疊）→ k（9dbcb5b＝20261127g，三卡堆疊改**渲染後實測**）**＋本機 8123 同步＋worktree `/private/tmp/ledger_sync-pwa-deploy-20261125`（deploy branch 慣例：commit 後 push HEAD:gh-pages；教訓——rsync --delete 會砍 worktree 的 .git 指標與線上獨有檔，須 --exclude .nojekyll/.last_build_id 並排除 landing/scan/zxing 維持線上結構；worktree 分支落後遠端時 push 會 non-ff——以 `git commit-tree <tree> -p <遠端HEAD>` 直接建 deploy commit 繞過）。測試：**298 全綠**（＋3 雙態測試；budget_form 測試改計算機輸入＋常駐鍵盤下 `ensureVisible` 捲至儲存／刪除鈕——測試視窗 600 高被常駐鍵盤擠出視區，真機 844 不受影響）＋analyze 0。**FE 整合測試暫停中之順手修復**：f02 綁定「金額欄下方顯示常駐計算機鍵盤」→「金額欄聚焦後顯示計算機鍵盤」＋移除既有壞步驟 `keypad-＝`（＝ 鍵 2026-10-24 已移除）＋`金額欄顯示 {value}` 改比對即時求值結果、f03 `review-save`（不存在）→`quick-entry-save`＋聚焦、specs/plan/tests/frontend feature 來源檔同步、dsl v1.24 鍵契約更新；f03 FR-S5 情境與 `review-cat/account-*` chip keys 過時（PM 2026-11-22 改版遺留）——待 FE 恢復另案改寫。**下一步**：PM 手機／桌面驗收新計算機互動（編輯交易＋預算為本批重點）；驗收後 source 走 commit＋MR 流程。**✅ PM 驗收 OK（2026-11-27）→ 已 commit＝fea73be 於新分支 `feat/keypad-focus-slide`——**✅ MR 已合併**（Merge PR #2，e5d0f8c 進 feature/ios-pwa）；後續 UI 修正（20261127d 直排修正）commit 於同分支待 MR。合併後本地切回 feature/ios-pwa。****（前一快照：）2026-11-26（T90 自適應掃描頻率＋iPhone 返回快速恢復＋QR 取景引導＋紀錄補全——feature/ios-pwa）**（PM 需求：①「辨識速度有辦法每秒 5–10 幀？」②「確認清單退回後鏡頭正常了，但要再等約一秒才顯示」③「忘記寫的工作內容記錄在 session」④「沒加入分支的檔案原因是什麼？」。**T90a 自適應掃描頻率**（已實作）：掃描迴圈改自排程（`_startScanLoop`/`_loopDelay`）——上一 tick ≤80ms（原生偵測路徑＝iPhone/桌面）→ **100ms＝10 fps**；≤120ms → 200ms＝5 fps；後備解碼重（紅米 RGBA 深掃）→ 1000ms 保護主執行緒；確認清單開啟中 400ms 慢輪詢（紅米要 5–10fps 需解碼出主執行緒＝Web Worker/zxing-wasm 另案）。**T90b iPhone 返回快速恢復**（已實作）：`restartPreviewFresh` 改**串流重用**——確認清單期間串流仍活著 → 直接綁到全新 video 元素/槽（跳過停軌＋600ms 釋放＋重新 getUserMedia≈1 秒＝**零黑屏瞬換**）；串流死才走重取（videoWidth==0 兜底 _openOn）。**T90c QR 取景引導**（已實作）：電子發票模式、無偵測框時顯示「把左右 QR 條碼放進框內」固定取景引導框。**PM 動作補記**（原未記錄）：①將 T89 系列程式 **cherry-pick 至 feature/ios-pwa**（f5577c0「0.5.1-pwa.20261125s 調整鏡頭回復與辨識速度」＋08cb05e「PICK 0.5.1-pwa.20261125s」——含程式＋文件＋html5qrcode 檔案退役）②建標籤：**優化辨識速度**＝b8a2830（T89b）、**鏡頭功能完整**＝4e74e21、**鏡頭辨識完成－需要小調整**＝fb55b4c（T89c）③**自行部署 gh-pages＝0.5.1-pwa.20261125q**（取代先前 s——CDN 已驗證線上＝q）④澄清：q/r/s 為 **gh-pages 部署版本戳**（非 git tag）。**測試補全**：ios-pwa 缺 T89 RGBA 直入單元測試（pick 未含）→ 已補。**未納入分支的檔案說明**（皆為 2026-11-21「LOGO/ICON 暫套＋相機診斷批」依 PM 指示「工作區 WIP 不 commit」保留）：README／pbxproj（圖示草稿 A 暫套）／MainFlutterWindow.swift（**DBG-017 修復**已 ✅ 結案——**已收編** 2026-11-26 PM 核准）／debug.md（DBG-017/018 記錄——**已收編**）／techstack.md（v0.3.13 圖示——**已收編**）／manifest.json（僅檔尾換行）；未追蹤＝.omo/.playwright-mcp（工具狀態，建議 gitignore）／BUILD_CLEANUP＋CROSS_PLATFORM_REFACTOR_GUIDE＋LOCAL_DEPLOY 三份指南（待 PM 決定）／jpg＋logo-drafts（LOGO 素材評估中）／ledger_backup_*.db（**真實資料備份——勿進 git**）／tool/*.ignore（廢棄草稿）／web/zxing（**T85 已退役 html5-qrcode 的殘留資產——建議刪除**）。✓295 全綠＋analyze 0。**T90d/e/f**（PM 回饋三點）：①「辨識時慢時快」＝**入單即清累積窗**（已入單的碼留窗內會擋下一張 2–3 秒＝掃完一張後下一張變慢的主因）＋新左碼清孤兒右碼（防跨發票混碼——parseOfficial 未驗證配對，右碼格式驗證待真實樣本另案）②「確認清單沒按 OK 直接退出→變連續掃描」＝自動進確認清單條件改「有新增就觸發」（原「prev 空」——按返回後草稿非空＝單張模式退化；按返回未存項目保留）③「iPhone 沒有提示」＝提示只在「只掃到右碼」部分狀態出現；iPhone 原生引擎＋10fps 一幀抓雙碼→即時入單無部分狀態（逐碼回饋＝teal 偵測框）。✓E2E 全流程。工作分支＝feature/ios-pwa。**PM 決策 2026-11-26**：「掃描發票帶入商家名稱」**先不做**（QR 內容無商家名稱、僅賣方統編——draft 已存 sellerTaxId；可行方案 A 統編記憶對應／B 政府開放資料查詢（公司登記才查得到）／C OCR 抬頭，留待日後）。（**2026-11-25 以前的每日快照**：已遷出 → `session-archive.md`） |
| 當前分支 | **feat/keypad-focus-slide**（fea73be 已推 origin——計算機改版批 18 檔；**MR 待合併**：compare/feature/ios-pwa...feat/keypad-focus-slide；合併後切回 feature/ios-pwa）。來源：**feature/ios-pwa**（origin 至 `2d7f12a`＝fake controller setFocusPoint 補齊；**main 亦同步至 f1f79b2＝v0.5.0+2 發版**；**tag v0.5.0 已推**）。另有 `pwa-acc**main 亦同步至 f1f79b2＝v0.5.0+2 發版**；**tag v0.5.0 已推**）。另有 `pwa-accumulate`（PWA 穩定線：8596c27 基底＋T52 明細修改＋累積合併＋看門狗）與 `camera-improvements`（鏡頭實驗凍結分支）。歷史：自 fix/quick-entry-v3-ledger-display `e1e90ff` 切出；已推 origin，11 筆提交至 `70bd21d`｜先前：fix/quick-entry-v3-ledger-display（e1e90ff 已推）；本地 main 仍領先 origin/main 未推｜先前：**main**（cadd29a 已 push）；本地分支已清；遠端僅 main／session/handoff |＝發票左碼聰明定位 2026-11-20；**11-21 批（相機切換＋LOGO）工作區 WIP 未 commit**）。歷史：自 fix/quick-entry-v3-ledger-display `e1e90ff` 切出；已推 origin，11 筆提交至 `70bd21d`｜先前：fix/quick-entry-v3-ledger-display（e1e90ff 已推）；本地 main 仍領先 origin/main 未推｜先前：**main**（cadd29a 已 push）；本地分支已清；遠端僅 main／session/handoff |
| 當前任務 | **計算機改版批驗收 OK**——MR 待合併（feat/keypad-focus-slide → feature/ios-pwa）。後續：①PM 走 0.5.0 發版驗收清單（release-0.5.0-checklist.md）②T45 PWA 黑畫面離線診斷 ③Big5 品名亂碼 ④T21 OCR 文字框 PWA 端 ⑤zxing-wasm 接線（camera 凍結範圍）——詳見 session-todo.md ⏳ |
| 環境筆記（①～㉗ 歷史全量） | 已遷出 → **`session-archive.md`**——新教訓記在本列下方 |
| ⏸️ FE 測試暫停（PM 2026-10-24） | **`integration_test/features/*` 一律不跑**（PM：很多東西還不正確，等指示再恢復）。期間護欄＝`flutter test`（test/：unit＋widget，含 `test/presentation/*` 頁面情境）＋`dart analyze`。**檔案保留**（analyze 維持 0；待恢復時再逐檔重跑並對齊當時 UI）。CI 只跑 `flutter test`，不受影響。 |
| 紅綠燈狀態 | `dart analyze` 0＋**unit/widget 298 全綠**（2026-11-27 計算機改版批；FE 暫停維持） |
| 工作區 | **計算機改版批已 commit**（fea73be 於 feat/keypad-focus-slide——18 檔：lib 六畫面＋keypad 元件＋測試五檔＋FE 整合測試修復＋specs/dsl/session 同步；**MR 待 PM 合併**）。**PM 自己的修改未 commit**（README/Xcode/manifest 等——AI 不動，PM 自行處理）。**gh-pages 已推＝0.5.1-pwa.20261127c（ab2298e）＝線上與本機 8123 皆此版**。歷史：WIP 未 commit（2026-11-21 批：相機切換/診斷＋LOGO/ICON 等） |
| truth 對齊 | techstack **v0.3.13**（2026-11-21：LOGO/ICON 素材授權＋相機批登記；歷史：v0.3.11（PWA 批登記：web 1.1.2／http 1.6.0／archive 4.7.1；**§6 SP-8 PWA Spike 結案**）（歷史：techstack v0.3.7（**待追加 googleapis／googleapis_auth／google_sign_in——需 PM 簽核**）；dsl v1.5；data-spec v0.3.2；debug.md DBG-001~007 結案；新增 `pm-actions.md` v0.1 |
| 阻塞／待決 | ⓪**MR 合併**（PM；feat/keypad-focus-slide → feature/ios-pwa）①**Google 憑證**（PM）②**商店帳號＋簽章**（PM）③**gh CLI 未安裝** ④T45 PWA 黑畫面診斷 ⑤Big5 品名亂碼 ⑥zxing-wasm 接線 ⑦FE 測試恢復（等 PM 指示；恢復時 f03 過時情境改寫）——歷史清單全量 → `session-archive.md` |

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
