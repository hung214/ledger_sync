# Session 工作清單（每輪工作前更新——PM 2026-11-22 要求，避免遺忘）

> 規則：每次收到 PM 回饋 → 先把 TODO 落到本檔 → 做完打勾 → 全數完成後保留紀錄。
> 未完成項目跨輪保留。發版前本檔應全數打勾。
>
> **分支現況**：
> - `feature/ios-pwa`（主線／APP）：全部最新功能（266→270 測試全綠）
> - `pwa-accumulate`（PWA 線）：8596c27 基底＋T52 明細修改＋累積合併＋看門狗
>   （部署 0.5.0-pwa.20261124d；**不含**分類選擇器升級/鏡頭實驗）
> - `camera-improvements`：鏡頭實驗凍結分支（PM 2026-11-24 指示）

## 進行中（PM 2026-11-24：PWA 補光開關——原推原生APP，現改 PWA）

- [x] **T58-PWA PWA 掃描頁補光（手電筒）開關**：
  web_camera_scan.dart（getUserMedia + MediaStreamTrack.applyConstraints torch）
  ②✓介面加 torch 能力＋開關按鈕（Key webcam-torch-toggle；右上角與切換鏡頭並排）
  ③✓測試（260 全綠＋analyze 0）
  ④✓已部署 0.5.0-pwa.20261124i（gh-pages，等 CDN 同步）
  ⚠️ PWA 鏡頭碼凍結線，但 PM 明示指示在 PWA 加補光開關，故可動

## 進行中（PM 2026-11-24：手機版補光開關）

- [x] **T58 手機 APP 掃描頁補光（手電筒）開關**：
  ①✓探查 native 掃描頁（mobile_scanner 7.5 toggleTorch/TorchState）
  ②✓介面加 torch 能力＋開關按鈕（Key scan-torch-toggle；iOS/Android 行動 APP；macOS 桌機不顯示）
  ③✓測試（274 全綠＋analyze 0）
  ④待 PM 實機走查（iOS/Android 手電筒開關）
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
