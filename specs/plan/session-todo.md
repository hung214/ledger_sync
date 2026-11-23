# Session 工作清單（每輪工作前更新——PM 2026-11-22 要求，避免遺忘）

> 規則：每次收到 PM 回饋 → 先把 TODO 落到本檔 → 做完打勾 → 全數完成後保留紀錄。
> 未完成項目跨輪保留。發版前本檔應全數打勾。
>
> **分支現況**：
> - `feature/ios-pwa`（主線／APP）：全部最新功能（266→270 測試全綠）
> - `pwa-accumulate`（PWA 線）：8596c27 基底＋T52 明細修改＋累積合併＋看門狗
>   （部署 0.5.0-pwa.20261124d；**不含**分類選擇器升級/鏡頭實驗）
> - `camera-improvements`：鏡頭實驗凍結分支（PM 2026-11-24 指示）

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
