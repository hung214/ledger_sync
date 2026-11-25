# Session 工作清單（每輪工作前更新——PM 2026-11-22 要求，避免遺忘）

> 規則：每次收到 PM 回饋 → 先把 TODO 落到本檔 → 做完打勾 → 全數完成後保留紀錄。
> 未完成項目跨輪保留。發版前本檔應全數打勾。
>
> **分支現況**：
> - `feature/ios-pwa`（主線／APP）：全部最新功能（266→270 測試全綠）
> - `feat/pwa-scan-ui-fix`（T84 修復分支，待 MR→ios-pwa）：掃描頁三重根因修復
>   （部署 0.5.1-pwa.20261125m；線上 E2E 已驗證）
> - `pwa-accumulate`（PWA 線）：8596c27 基底＋T52 明細修改＋累積合併＋看門狗
>   （部署 0.5.0-pwa.20261124d；**不含**分類選擇器升級/鏡頭實驗）
> - `camera-improvements`：鏡頭實驗凍結分支（PM 2026-11-24 指示）

- [x] **T87 預覽貼邊＋解析度上限**（PM 2026-11-25「鏡頭畫面變小；第二次
  掃描又更小；要左右貼邊」）：**根因**＝video 元素無 CSS——以**原生
  解析度**渲染（1920×1080 在預覽槽＝放大裁切；且每次重取相機談判解析度
  不同——ideal 允許更高（4K）→每次進頁觀感跳動）。**修復**：①video CSS
  固定 100%×100%＋object-fit:cover（相機 App 標準填滿、置中裁切——
  解析度變動不再影響觀感；解碼吃全幀不受顯示裁切影響）②約束加
  **max 1920×1080**（三路徑：初次/facingMode、deviceId 精選、切換——
  防 4K 截幀拖慢 tick＋穩定談判）。E2E 量測 videoRect＝slotRect（貼邊）。

- [x] **T88 掃描偵測框**（PM 2026-11-25「掃到條碼要有框」）：原生
  BarcodeDetector 的 **boundingBox**（video 像素座標）接入——
  DetectedCode（camera_stream 介面＋native/stub）→ 頁面 Stack 疊
  CustomPaint（_CodeBoxesPainter：object-fit:cover 映射後畫 teal 圓角
  框＋淡填充，左右雙 QR 各一框；無偵測＝清空）。**註**：zxing2 後備
  路徑無框（image_qr_scan 未回座標——未來增強）；前鏡頭鏡像未映射
  （掃描主流＝後鏡頭）。

- [x] **T86 紅米辨識修復＋雙引擎＋tick 死鎖防護＋照片按鈕**（PM 2026-11-25
  三線索：①紅米 Note 11 Pro 5G 辨識不到（iPhone 17 Pro 可）②「切換鏡頭
  再切回來就突然變得容易辨識」③「第一張掃到之後其他張就順＋感覺有
  功能卡住」——**根因**：`_acquireRearCamera` 的 deviceId 精選重取
  **丟失 hiRes 約束**（只給 deviceId＝Android Chrome 開 640×480 預設檔，
  QR 模組過小；多後鏡頭機型必觸發）——switchCamera 路徑走
  _tryGetUserMedia（有 hiRes）→ 切換來回後解析度升級＝PM 觀察的「變好」。
  **修復**：a. 精選重取帶回 width/height ideal 1920×1080
  b. **雙引擎併聯**——原生 BarcodeDetector 沒中→同 tick zxing2 擷幀
  （Android Chrome 偵測器存在但底層不作用時不再卡死；每 tick 截圖＝
  照片附件來源；診斷行加「引擎 原生/後備」）
  c. **tick 死鎖防護**——_tryDecode 包 try/finally（原寫法擷幀/解碼擲
  例外＝_decoding 永遠 true＝掃描迴圈死鎖＝「功能卡住」）＋captureFrame
  readyState 檢查＋解碼器例外防護
  d. **確認清單照片**（PM：有變形＋不用直接顯示）——預設隱藏＋
  「顯示照片」按鈕（逐張重設）；顯示時一般照片 BoxFit.contain
  （原 fill 把 16:9 幀塞 4:3 框＝拉扁）；OCR 框項目保留 fill（T21 對位）
  ✓291 全綠＋analyze 0✓本機＋線上 E2E（照片按鈕截圖）✓部署
  **0.5.1-pwa.20261125o** → 待 PM 真機驗收（紅米重開 PWA 待 SW 換版，
  版本戳 20261125o；診斷行解析度應為 1280×720 以上）

- [x] **T85 掃描架構回歸 pwa-0.5.2＋TwEin 疊加**（PM 2026-11-25 指示
  「回到 pwa-0.5.2 重新處理」——T84 修復版（html5-qrcode）實機仍三問題：
  ①半透明方框遮罩＋video 溢出遮住選單按鈕 ②辨識良率沒變好 ③中央
  掃描窗是一維條碼式框選，不是電子發票用。**定調**：遮罩/掃描窗/video
  溢出皆 html5-qrcode 內建行為（無法關）——整組退役；真正有價值的是
  TwEin 官方解析（與引擎無關）→ 疊回 pwa-0.5.2 架構）：
  - **回歸**：web_camera_scan＋測試 checkout pwa-0.5.2（PM 驗證版——
    無遮罩/無掃描窗/無距離提示/全畫面偵測）；camera_stream* 保留
    （＝pwa-0.5.2＋T82 zoom 介面，1920×1080 約束 pwa-0.5.2 已內建）
  - **TwEin 保留**：新 `tw_ein_parse.dart`（web/stub 條件匯出；解析層與
    引擎解耦）——累積窗文字 → safeParseInvoiceQr（右碼可缺＝省略參數）
    → 草稿；後備＝既有 ImageQrScanner.draftFromQrTexts
  - **退役**：html5qrcode_scanner*.dart＋web/scan/html5-qrcode.min.js
    ＋index.html script（tw-einvoice.js 留）
  **驗證**：291 全綠＋analyze 0＋本機 E2E（假相機 PM 真發票 IMG_2073）：
  video 在 flutter-view 1280×720、**無 qr-shaded-region**、TwEin success
  （發票號/日期/金額 21）→ 自動進確認清單 ✓；空白鏡頭截圖：模式切換/
  底部按鈕全可見＝**遮擋根除**。✓部署 **0.5.1-pwa.20261125n**（14:26
  CDN ✓）＋線上 E2E 同測通過 → 待 PM 真機驗收（版本戳 20261125n）
  → MR feat/pwa-scan-ui-fix → feature/ios-pwa

- [x] **T84 PWA 掃描頁修復**（被 T85 取代——三重根因修復證明了
  html5-qrcode 整合層能動，但其內建遮罩/掃描窗/video 溢出不符合
  發票掃描 UX，最終由 T85 回歸 pwa-0.5.2 架構；經驗留存：JS 互操作
  全域必須顯式名、callMethodVarArgs、platform view 掛 Flutter 樹內）

- [x] **T80 繳款顯示標籤**：repayment 不建真分類（轉移語意——掛
  expense/income 會污染分類統計/選擇器/預算）→ **顯示層固定標籤
  「信用卡繳款」**（明細手機標題／桌面分類欄／總覽最近交易——
  原「未分類」/「交易」；圖示圓 💳），資料保持 categoryId=null。
  ✓290 全綠＋analyze 0✓部署 0.5.1-pwa.20261124j（CDN ✓）

- [x] **T81 還款/轉帳流向顯示**：明細列副標加「→ 目標帳戶」
  （「現金 → 示例卡 · 已繳」——雙端流向一目了然；統計口徑不變
  ——還款不計收支的會計語意已向 PM 說明並同意）✓290 全綠
  ✓部署 0.5.1-pwa.20261124k（CDN ✓）

- [x] **T81-② 標籤覆蓋補完**：PM 回報①最近刪除顯示「未分類」
  ②總覽顯示「交易」。②根因＝**T80 總覽用了字串比較（Tx entity 是
  enum）恆 false——T59 同款陷阱**（明細頁 TxRow 字串 ✓ 所以正常）。
  修復＝enum 比較＋最近刪除頁固定標籤＋💳＋回歸 widget 測試。
  ✓291 全綠＋analyze 0✓部署 0.5.1-pwa.20261124l（CDN ✓）。

- **未來項（PM 2026-11-24 暫緩）**：**轉帳手續費**——快記轉帳加
  手續費欄，儲存時自動產生一筆手續費支出（推薦挂系統分類「轉帳
  手續費」，計入支出統計；零 schema 變更）。設計已評估，PM 決定
  先不做——需要時直接接手。

- [x] **T82-② PWA zoom 補償**：PM 回報自動變焦只有 MAC APP 有、
  PWA 沒有——T82 首輪只做 native 路徑。補齊＝CameraStreamController
  介面加 zoomSupported/setZoom（capabilities.zoom 動態探測——iOS
  Safari 常見不支援→只顯示距離引導）＋web_camera_scan 無偵測
  4 輪（≈4.8s）升檔 1.5×→2×→2.5×＋常駐引導。✓291 全綠＋
  analyze 0✓部署 0.5.1-pwa.20261124n（CDN ✓）。

## 已完成（PM 2026-11-25：T87/T88 預覽貼邊＋掃描偵測框——待 PM 真機驗證）

- [x] **T87 預覽貼邊＋解析度上限**／**T88 掃描偵測框**（詳見本檔頂部
  區塊）：PM 實測 T86「成功機率變快很多」✓；新回饋「鏡頭畫面變小、
  第二次更小、要左右貼邊」＋「掃到條碼要有框」→ video CSS cover＋
  max 上限＋boundingBox 偵測框。

- [ ] **PM 真機驗證**（重開 PWA 待 SW 換版——版本戳見部署）：
  ①鏡頭預覽**左右（上下）貼滿**預覽區，且每次進掃描頁尺寸一致
  ②掃到條碼時畫面上出現**teal 圓角框**（雙 QR 兩框）
  ③紅米辨識率維持 T86 水準（診斷行解析度 ≤1920×1080）

- [x] **T85 掃描架構回歸 pwa-0.5.2＋TwEin 疊加**（詳見本檔頂部區塊）：
  分支 `feat/pwa-scan-ui-fix`（待 MR→ios-pwa）✓291 全綠＋analyze 0✓
  部署 **0.5.1-pwa.20261125n**（14:26 CDN ✓）✓本機＋線上 E2E：
  解碼→TwEin success→草稿→確認清單（金額 21／日期 10/17／發票號
  SR30393603）＋空白鏡頭截圖無遮擋 ✓

- [ ] **PM 真機驗證**（重開 PWA 待 SW 換版——版本戳 **20261125n**；
  驗收：①掃描頁無遮擋——選單/按鈕全可點 ②掃真發票良率 ③無掃描窗
  框選（全畫面偵測）④可正常退出掃描頁）

- [x] **T83 掃描技術替換**（PM 2026-11-24 指示；回退保險＝tag `pwa-0.5.2`）：
  - html5-qrcode (UMD) 相機掃描＋tw-einvoice-qr (IIFE) 官方規格解析
  - 移除 platform view 改直接建立 div，registerReaderView 直接掛載 DOM
  - TwEin 解析（左碼/右碼/Code39/77碼/品目/Base64/境外/對獎）＋既有解析器後備
  - 保留確認清單/節流/去重/補光/診斷/手動開一筆
  - 292 測試全綠＋analyze 0✓部署 `0.5.1-pwa.20261125k`（CDN ✓）
  - headless 驗證：JS globals（Html5Qrcode function＋TwEin 14 API）零錯誤
  - 回退保險：`pwa-0.5.2`（舊技術）＋`pwa-0.5.3-techno`（新技術基準）

- [ ] **PM 真機驗證**（iOS PWA 掃真發票——左右碼＋Code39）
  - 有問題即回退 `pwa-0.5.2`（一鍵回退）

## 進行中（PM 2026-11-24：T83 PWA 掃描技術替換——html5-qrcode＋tw-einvoice-qr）

- [ ] **T83 掃描技術替換**（PM 指示；回退保險＝tag `pwa-0.5.2`）：
  - [x] ①套件調研＋資源放置：web/scan/html5-qrcode.min.js（UMD 2.3.8）
    ＋tw-einvoice.js（esbuild IIFE→window.TwEin，11.9KB——parseBarcode
    驗證 ✓）
  - [x] ②web/index.html 引入兩個 script
  - [x] ③Dart 互操作層：html5qrcode_scanner.dart（條件匯出——stub
    保 native 編譯；web 實作＝Html5Qrcode start/stop/torch＋TwEin
    解析 dartify→純 Dart 結構）
  - [x] ④web_camera_scan 改造：掃描區換 reader div（platform view）、
    onSuccess 驅動（移除 _loop/_tryDecode 舊迴圈）、累積窗重用＋
    TwEin parseInvoiceQr→TransactionDraft 轉換、保留確認清單/節流/
    去重/補光/診斷行/手動開一筆
  - [x] ⑤測試：analyze＋292 全綠＋互操作測試（fake scanner 5 情境）
  - [x] ⑥headless 冒煙：JS globals（html5qrcode function／TwEin object
    14 API）✓零 JS 錯誤✓（serve 目錄修正後——base-href 前綴陷阱）
  - [x] ⑦部署 0.5.1-pwa.20261125a（CDN 驗證＋scan/ 資源 200 ✓）＋
    兩線同步＋tag pwa-0.5.3-techno（新技術基準）
  - [ ] ⑧**PM 真機驗證**（iOS PWA 掃真發票——左右碼＋Code39；
    出問題回退 pwa-0.5.2）
  - **設計決策**：不建真分類沿用；解析走 TwEin（官方規格 v1.9 完整
    實作——左右雙碼/品目/Base64/境外/對獎）；出問題回退 pwa-0.5.2

## 進行中（PM 2026-11-24：掃描發票覆盤——對焦/辨識優化）

- [x] **T82 掃描覆盤優化**：覆盤結論——①發票 QR＝高密度 V13
  （77×77 模組）→ 需拉近但撞 MOFO 物理對焦極限（機型差異 6~15cm）
  ②autoZoom=true **僅 Android**（上游限制——iOS 無變焦補償）
  ③QR＋Code39＋Code128 同開→MLKit 每幀負載↑（單一 QR 快的對照）。
  **優化**：Dart 層跨平台 zoom 補償（無偵測 5s→1.5×→2×→2.5×＋
  常駐引導「拉遠 15~20cm」——繞過 MOFO 的數位微距）＋autoZoom=false
  （統一 Dart 層控——重用既有正規化 zoom 狀態，與手動 1×/2×/3× 按鈕
  同步）＋web 診斷行距離提示。✓291 全綠＋analyze 0✓部署 20261124m。
  **待 PM 真機驗證**（其他手機：靠太近 → 5 秒後自動變焦＋引導）。

## 進行中（PM 2026-11-24：平帳修復＋帶入收窄＋輸入提示）

- [x] **T79 信用卡平帳修復**：PM 回報繳款後總覽帳戶沒有平帳。
  根因＝總覽帳戶列**信用卡行誤用 assetBalance**（repayment 信用卡
  端屬負債面不計——公式註解明載）→ 繳款後恆顯示 −消費額。修復＝
  信用卡列改「應付 N」（creditUnpaidTotal，與明細頁一致；還款即
  扣減）✓1 widget 測試（應付 500→0＋現金 5,000→4,500）✓部署
  0.5.1-pwa.20261124i（CDN ✓）
- [x] **T78-① 帶入範圍收窄**：選分類帶入**僅金額/商家**——
  帳戶不動（PM 指正）。✓selectCategoryById 移除記憶帳戶帶入
  ✓回歸測試（記憶 accountId 路徑不再覆蓋）
- [ ] **T78-② 商家/備註輸入提示**：輸入文字時即時提示歷史內容
  （可點選填入、可繼續打字）——實作中。

## 進行中（PM 2026-11-24：快記直接繳卡費）

- [x] **T77 快記繳卡費**：快速記帳即可繳卡費（免進信用卡頁）。
  ①快記第四模式「繳卡費」（僅有信用卡帳戶時顯示）②金額預設
  帶入「未繳合計」（creditUnpaidTotal，可改）③儲存走
  RepayStatementUseCase（有未繳清帳單→帳單累加＋繳清取消 N-5；無→
  純 repayment 交易）✓execute 加 fromAccountId（使用者選擇優先）
  ✓repayment 不計收支統計✓3 controller 測試＋288 全綠＋analyze 0
  ✓部署 0.5.1-pwa.20261124h（CDN ✓）

## 進行中（PM 2026-11-24：預算摘要金額語意修正）

- [x] **T76 預算摘要金額語意修正**：**PM 指正——金額是台幣，
  不用除 100**。本專案 amountMinor 單位＝台幣元（TWD zero-
  decimal，非「分」）。T74 的 `~/ 100` 顯示縮小 100 倍（8,000 元
  顯示 80）＝「數字不是完整的數字」根因。✓移除 ~/ 100 直接
  format ✓修正 T74/T71 測試的 ×100 錯誤語意 ✓285 全綠＋
  analyze 0✓部署 0.5.1-pwa.20261124g（CDN ✓）。
  **教訓**：金額單位語意先查 BDD 資料流（f05 `_amount`=直接
  parse），勿以「minor=分」慣例假設。

## 進行中（PM 2026-11-24：PWA 更新看不到——SW 自動重載）

- [ ] **T75 SW 自動重載**：iOS PWA standalone 開啟＝先吃舊快取，
  SW 背景更新（skipWaiting）後頁面仍跑舊 JS（無 controllerchange
  → reload）→ PM 要殺掉重開才看到。index.html 加 controllerchange
  → location.reload()：新 SW 接管即自動重載，免手動重整。

## 進行中（PM 2026-11-24：總覽預算摘要對照雛型）

- [x] **T74 總覽預算摘要修正**（對照 specs/plan/ui/01-dashboard.html）：
  原本只有光禿進度條 → 雛型樣式＝名稱（粗體）＋「7,000 / 8,000
  （87.5%）」＋8px 進度條＋⚠ 門檻警示行（≥80% 琥珀、超支紅換文案、
  <80% 無行）；色階 AC-05；百分比一位小數。BudgetProgressBar 維持
  純進度條（budget_page 自帶名稱列）。2 widget 測試＋285 全綠＋
  analyze 0。部署 0.5.1-pwa.20261124e（CDN ✓）。
  ⚠流程註記：T74 commit 誤在 ios-pwa 直線提交（漏開分支），
  內容已同步 pwa-accumulate；下輪恢復「新分支→合併」流程。

## 進行中（PM 2026-11-24：快記連續記帳保留日期）

- [x] **T73 快記日期保留**：「繼續」不再重設時間為現在——
  維持最後設定日期（補記場景）；重新進入快記（首頁＋）＝當日
  （autoDispose 重建即 preset.time）。同步驗收文件 S1.7。

## 進行中（PM 2026-11-24：快記切分類保留已輸入金額）

- [x] **T72 快記帶入守衛**：選分類帶入上次資料（金額/帳戶/商家）
  現會覆蓋已輸入金額——金額非 0 時**不帶入**；金額 0/空照舊。

## 進行中（PM 2026-11-24：預算主分類加總）

- [x] **T71 預算主分類加總**：PM 需求——預算可選主分類，
  已花費＝該主分類＋其全部子分類加總（早餐100＋午餐200 →
  「餐飲食品」顯示 300）。✓evaluator 主分類 self+children 集合比對
  （子分類預算維持精確；pending 照舊）✓選擇器 pickMainLabel 參數
  （預算＝「整個主分類（含子類別）」）✓清單列標示「（含子類）」
  ✓5 新測試＋279 全綠＋analyze 0✓部署 0.5.1-pwa.20261124b（CDN ✓）

## 進行中（PM 2026-11-23：iOS PWA 選檔修正）

- [x] **T70 iOS PWA 選檔修正**：PM 實測——資料管理「從檔案還原」
  筆電/桌機正常、iPhone 找不到檔案。根因＝file_selector 的
  openFile() 依賴 File System Access API（iOS Safari 僅支援
  image/video）。修復＝web 分流 `<input type="file">`（條件匯出
  web_file_picker*，cancel 事件監聽）；還原 .db/.json＋CSV 匯入
  兩處接線；274 全綠＋analyze 0；部署 0.5.1-pwa.20261123a
  （CDN 驗證 ✓）；iPhone 檔案來源＝檔案 App/iCloud/AirDrop。

## 進行中（PM 2026-11-23：品牌定稿——ICON 換裝＋首頁左上 LOGO）

- [x] **T69 ICON/LOGO 定稿換裝**：icon 來源改 `jpg/icon01.png`
  （滿版無圓角——系統自套圓角，避免雙層圓角）；logo.png → 首頁
  左上角 LOGO。✓flutter_launcher_icons 重產全平台（iOS 壓平/macOS/
  Windows/Android adaptive/web favicon+maskable）✓側欄 📒→定稿圖示
  ＋白字（Expanded 防 Ahem 溢出；desktop_shell_test 斷言同步更新）
  ✓logo.png 白底直式不硬塞 AppBar（PM 同意）✓274 全綠＋analyze 0
  ✓5aeda75→merge ios-pwa＋macOS 重建 PM 目視

## 進行中（PM 2026-11-23：相機修復完成——MR 回流＋發佈 0.5.1）

- [x] **T67 相機修復 MR 回流**：pwa-accumulate（T61-T66 相機修復）
  → merge 回 feature/ios-pwa ✓（web_camera_scan＋camera_stream 系列取凍結線
  測試版；補完 5 檔衝突解決——c82b344；274 全綠＋analyze 0）
  ✓**pwaCmara.md** 處理全記錄文件（根因三層＋解法演進＋教訓）
- [x] **T68 發佈 0.5.1**：pubspec 0.5.1+1＋CHANGELOG＋全測試 →
  ✓merge main（894c56d）＋**tag v0.5.1 已推**（CI 發佈）＋macOS 重建 ✓
  ✓PWA 標章 0.5.1 部署（CDN 驗證）✓CHANGELOG 0.5.1 區段
  ✓pwaCmara.md 處理全記錄

## 🔴 進行中（PM 2026-11-23：PWA 相機黑畫面復發——T57 回歸）

- [x] **T61 黑畫面回退（立即）**：✓相機 5 檔回退至 59591ee（凍結線＋補光版）；
  設定頁/預算/總覽修改保留 ✓部署 20261124s（CDN 驗證）✓pwa-accumulate 已 commit
- [x] **T62 生命週期釋放（PM 2026-11-23 研究方案）**：
  ✓hidden → 立刻停軌＋清 srcObject（釋放相機硬體鎖，不留殘屍）
  ✓visible → 延遲 300ms（等硬體釋放）→ 重取串流（失敗靜默，看門狗後備）
  ✓video autoplay/playsinline/muted 屬性已有
  ✓**PM 驗證：背景/前景恢復正常**（T62 生效）
- [x] **T63 重進掃描黑畫面（PM 2026-11-23：第一次正常、重進仍黑）**：
  根因＝iOS 停軌後相機管線未完全重置，重取得黑串流。
  ✓_openOn 重構：取得後**背景驗證幀流動**（採樣亮度），黑 → 停軌＋
  清掛載＋**遞增延遲（400/800/1200ms）重取**（最多 4 輪）
  ✓_openGen 世代計數（重進/切鏡頭/看門狗重取→舊迴圈自動失效）
  ✓部署 20261124t——**PM 驗證：仍黑（session 內只有第一次啟動有畫面，
  之後全黑，強制關閉 PWA 才恢復；APP 原生相機從無此問題）**
- [x] **T64 全程保活根治（PM 2026-11-23）**：session 內停「已啟動」相機
  ＝管線毒化，之後所有 getUserMedia 皆黑。唯一可行策略＝**串流＋元素
  全程保活**（T41 失敗根因＝重建新元素）：
  ✓_sharedVideo session 唯一元素＋單次 viewFactory 註冊
  ✓_keepAliveStream 活著 → 重接同一元素（不自願停軌）；死軌（首次/
  系統回收）→ 全新取得
  ✓dispose 只分離引用（不停軌不清 srcObject）
  ✓保留 T62 visibility（背景＝系統回收路徑，PM 已驗證）＋T63 幀驗證
  ✓代價：離開掃描頁後相機燈持續亮
  ✓部署 20261124u——**PM 驗證：重進有畫面 ✓，但①離開掃描頁相機燈
  仍亮（不對）②手動關閉後無法再開**
- [x] **T65 離開即關燈＋重進整頁重載（最終策略，PM 2026-11-23）**：
  ✓dispose 停軌清掛載（**離開即關燈**）＋sessionStorage 標記
  ✓start 偵測標記 → **整頁重載**（乾淨 context＝第一次啟動行為——
  PM 已驗證可靠）→ pending 旗標
  ✓AppRoot 重載後自動導回掃描頁（kIsWeb＋已引導＋未鎖定；
  pending_scan_nav.dart 條件匯出隔離——native 測試不受影響）
  ✓verify-heal 4 輪失敗 → 重載後備（上限 2 次防迴圈；成功清計數）
  ✓部署 20261124v（CDN 驗證）＋pwa-accumulate 已 commit
  部署 20261124v——**PM 驗證：第二次進掃描「相機啟動失敗：
  NoSuchMethodError 'dz'」**
- [x] **T66 NoSuchMethodError 根因（headless Chrome 重現）**：
  **`?? const []` 型別降級 bug**（T62 引入）——空字面量無上下文推斷
  List<dynamic>，與 List<MediaStreamTrack> 的 LUB 降級迴圈變數為
  dynamic → interop `.stop()` 變動態派發 `stop$0`（minified 'dz'）→
  raw JS 軌道物件缺 Dart selector → 炸。首次進入串流 null＝空列表
  僥倖不炸；串流活著（離開掃描頁再進）必炸。
  ✓修復：5 處改 `_videoTracks()`（null 檢查＋型別正確 List）
  ✓headless Chrome（profile build＋fake camera）重現→修復驗證
  ✓**自動導航 Navigator 修復**：AppRoot context 在 MaterialApp 之上
  → Navigator.of null check 炸 → 移至 MainShellPage（下層）✓
  ✓headless 二驗：兩次進入**零錯誤**＋假相機畫面正常渲染＋幀流動
  ✓260 測試全綠＋analyze 0

## 🔴 進行中（PM 2026-11-23：總覽最近交易支出/收入正負反了）

- [x] **T59 總覽最近交易正負號修正**：
  ①✓找到 bug：_RecentTxRow 以 tx.kind == "expense" 比較，但 txEntity 映射後 tx.kind 是 TxKind enum → 永遠 false → 全部顯示 +
  ②✓修正為 tx.kind == TxKind.expense（支出 −、收入 ＋）
  ③✓測試（274 全綠＋analyze 0）
  ④✓**APP 正確**（macOS 重建驗證）、**PWA 修正並部署**（0.5.0-pwa.20261124j，等 CDN 同步）
  ⑤✓新分支 fix/overview-recent-transactions-sign 已推，待 MR 到 feature/ios-pwa
  ⚠️ 新工作流程的首個範例：新分支＋MR 到 ios-pwa，不直接合併 main

- [x] **T60 設定頁區塊順序調整 + 說明文字 + 主題三狀態按鈕**：
  ①✓區塊順序：外觀 → 資料 → 安全 → 同步（原：同步 → 資料 → 安全 → 外觀）
  ②✓資料管理副標題更新
  ③✓主題模式改為單一三狀態循環按鈕（系統→淺色→深色→系統）
  ④✓測試 274 全綠＋analyze 0
  ⑤✓**PWA 部署 0.5.0-pwa.20261124m** + **macOS 重建啟動**

## 📋 工作流程修正（PM 2026-11-23 指示）

- [x] **W1 工作流程規則（PM 2026-11-23 指示）**：每項修改/功能都建立**新分支**，完成後一次 MR 到 `feature/ios-pwa`
  ❌ 錯誤做法：直接在 feature/ios-pwa/main 修改＋推送（已發生 T21/T23/T57/T58/0.5.0 發版）
  ✅ 正確做法：`git checkout -b feat/xxx` → 修改＋commit → `git push origin feat/xxx` → **MR 到 `feature/ios-pwa`**
  ⚠️ 等全部工作完成並經 PM 確認後，再統一 MR `feature/ios-pwa` → `main`
  ⚠️ 現狀：feature/ios-pwa 已累積多筆 commit（T21 OCR 框、T23-diag、查詢面板同步、
  0.5.0 版本 bump、T57 PWA 回退、T58 補光開關）——這些已在遠端，不再回滾，
  僅作為歷史參考；未來工作一律新分支

## 進行中（PM 2026-11-24：PWA 補光開關——原推原生APP，現改 PWA）

- [x] **T58-PWA PWA 掃描頁補光（手電筒）開關**：
  web_camera_scan.dart（getUserMedia + MediaStreamTrack.applyConstraints torch）
  ②✓介面加 torch 能力＋開關按鈕（Key webcam-torch-toggle；右上角與切換鏡頭並排）
  ③✓測試（260 全綠＋analyze 0）
  ④✓已部署 0.5.0-pwa.20261124i（gh-pages，CDN 已同步；PM 確認補光正確）
  ⚠️ PWA 鏡頭碼凍結線，但 PM 明示指示在 PWA 加補光開關，故可動

## 進行中（PM 2026-11-24：手機版補光開關）

- [x] **T58 手機 APP 掃描頁補光（手電筒）開關**：
  ①✓探查 native 掃描頁（mobile_scanner 7.5 toggleTorch/TorchState）
  ②✓介面加 torch 能力＋開關按鈕（Key scan-torch-toggle；iOS/Android 行動 APP；macOS 桌機不顯示）
  ③✓測試（274 全綠＋analyze 0）
  ④✓PM 確認補光正確（iOS/Android 手電筒開關）
  ⚠️ 僅行動 APP 線——**PWA 凍結線不動**（web 端 torch 支援度
  不一，且鏡頭碼凍結中）

## 🔴 進行中（PM 2026-11-24 回報：0.5.0 相機黑畫面復發）

- [x] **T57-PWA 回退（最優先）**：gh-pages 從 main（0.5.0，含鏡頭
  實驗碼）回退到 pwa-accumulate 穩定線（20261124g 最後確認可用）
  → 重部署新標章 20261124h
- [x] **T57-diag 黑畫面根因定位**：diff 完成。**肇因候選（web 線獨有）**：
  ①`_keepAliveStream`（T41——dispose 不停軌＋重進重用；Safari 對
  「新 video 元素接舊串流」可能不渲染＝燈亮黑畫面）②`_openOn` 新增
  absolute/object-fit:contain 樣式（首進差異點）。兩者皆鏡頭實驗碼，
  pwa-accumulate 凍結線刻意排除＝可用版。修法待 T45 headless 驗證
- [x] **T57-macOS 確認**：pub-cache Swift patch（1080p preset）
  是否仍存在＋macOS 相機驗證
- [x] **教訓記錄**：0.5.0 發版時誤把 main 全碼部署 PWA——
  PWA 部署線必須永遠走 pwa-accumulate（凍結線），除非黑畫面根治

## ✅ 已完成並驗證（本輪 audit 確認）

| 項目 | 驗證方式 | 狀態 |
|---|---|---|
| 官方規格解析（全平台掃描根因） | 266 測試＋實照 2073 完整入單 | ✅ |
| 紙本 OCR（2075/2076 驗證） | Swift Vision 實測 EF20947672 ✓ | ✅ |
| 電子/紙本分流（PM 指示） | scan_policy＋匯入管線分流測試 | ✅ |
| 時間預設＝當下時刻（PM 指示） | review 測試（occurred hour/min） | ✅ |
| 2076 發票號修正（EF26987585） | OCR 回歸測試（實照行） | ✅ |
| 確認卡快記同款＋鍵盤遮擋修正 | review/quick_entry 測試 | ✅ |
| 資料管理移除輸入確認文字（PM 指示） | wipe 測試 2 案例更新 | ✅ |
| 明細查詢按鈕＋待確認移除＋搜尋擴大 | search_coverage_test 4 案例 | ✅ APP＋PWA |
| 掃描 FAB 移除（入口統一快記右上角） | scan_entry_test 更新 | ✅ APP＋PWA |
| 黑畫面看門狗＋串流 keep-alive | pwa-accumulate 測試 256 綠 | ✅（PWA 線） |

## ⏳ 未完成（跨輪追蹤——依 PM 優先序排）

- [ ] **T45 PWA 黑畫面離線診斷**（headless Chrome：掃描頁進出→video
  渲染狀態）——20261124b/c 實驗版仍有黑畫面；凍結版（20261123）無此問題
- [x] **T23-diag 診斷行短格式**（PM 2026-11-23：「幀 N 命中 N 解 N ms」
  就好——點擊展開詳細）——camera 凍結中，隨 T45 一起做
- [x] **T21 OCR 文字框**：確認卡照片預覽帶辨識區域框（iOS/macOS）
- [ ] **Big5 品名亂碼**（QR 編碼參數 0 的明細——需 Big5 對照表）
- [ ] **zxing-wasm 升級**（研究完成：MIT、多碼、tryRotate/tryInvert、
  快 3-4 倍——檔案已下載 web/zxing/ 未接線；屬 camera 凍結範圍）

## ❓ 待 PM 提供／決策

- [ ] **發版 0.5.0 驗收**（release-0.5.0-checklist.md；掃描三平台可用）
- [ ] Google 憑證（雲端備份/同步；等 PM 建立）
- [ ] 測試發票圖檔授權（fixtures 入版控與否——個資）

## 已確認版本

- **APP**：最新（1baa1b9+）——全部功能
- **PWA**：`0.5.0-pwa.20261124d`（pwa-accumulate）——含明細查詢/待確認移除/
  搜尋擴大/累積合併/看門狗；**不含**分類選擇器升級（T60 候選）與鏡頭實驗
