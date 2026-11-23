# PWA 相機黑畫面處理全記錄（pwaCmara.md）

> **用途**：完整記錄 2026-11-21~11-23 PWA 相機黑畫面問題的診斷過程、根因層次、
> 解法演進與最終架構——供未來相機/webview 問題快速對照，避免重蹈覆轍。
> **結論先行**：iOS PWA（WebKit webview）的 getUserMedia 相機有三層地雷，
> 最終解法＝「離開即關燈＋重進整頁重載＋自動回掃描頁」，PM 實機驗證通過
> （0.5.0-pwa.20261124w）。

---

## 1. 問題時間線（PM 實機回饋）

| 日期 | 版本 | 症狀 | 判讀 |
|---|---|---|---|
| 11-21~22 | 多版 | 相機燈亮但黑畫面；退出重進也黑 | 初判「session 未釋放」 |
| 11-23 | 0.5.0 發版後 | **又**黑（main 實驗碼誤部署 PWA） | 凍結線策略破功（人為） |
| 11-23 | 20261124h | 回退凍結線 → 可用 | 確認實驗碼＝肇因 |
| 11-23 | 20261124s（T62） | 背景返回恢復 ✓，**重進掃描頁仍黑** | 前景重取路徑另有問題 |
| 11-23 | 20261124t（T63） | **第一次有畫面，之後全黑**；強制關閉 PWA 才恢復 | 毒化是 session 級 |
| 11-23 | 20261124u（T64） | 重進有畫面 ✓，但**燈不滅**＋**手動關後打不開** | 保活代價難接受 |
| 11-23 | 20261124v（T65） | 第二次進掃描「**相機啟動失敗：NoSuchMethodError 'dz'**」 | 新錯誤（Dart 層） |
| 11-23 | 20261124w（T66） | **完全成功**：燈滅／重進有畫面／無錯誤 | 三層根因全數修復 |

**對照組**：原生 APP（iOS/Android/macOS，mobile_scanner→AVFoundation/MLKit）
**從無此問題**——整個問題是 WebKit PWA webview 專屬。

---

## 2. 根因：三層疊加

### 層次一：WebKit PWA 相機管線「毒化」（平台特性）
- session 內**已啟動（engaged）的相機一旦被 `track.stop()`**，相機管線進入壞狀態；
- 之後**所有 `getUserMedia()` 都拿到黑串流**（stream live、燈亮、畫面黑）；
- 唯一恢復方式＝**殺掉 PWA process 重開**（強制關閉）；
- 例外：**退背景時的停軌不毒化**——iOS 系統本來就會回收相機，回前景重取
  ＝乾淨路徑（PM 驗證 T62 可用）。
- 佐證：首次啟動前的「暖機式停軌」（grab→立即 stop，相機尚未 engage）不毒化。

### 層次二：video 元素與串流的綁定（T41 教訓）
- 串流保活但**重建新 `<video>` 元素**去接 → 黑（T41 失敗根因）；
- 元素是渲染管線的錨點，新元素未必初始化成功。

### 層次三：Dart interop 的 `?? const []` 型別降級（T66，自傷）
```dart
_stream?.getVideoTracks().toDart ?? const []   // ❌
```
- 空字面量 `const []` 無上下文 → 推斷 `List<dynamic>`；
- 與 `List<MediaStreamTrack>` 的 LUB＝`List<dynamic>` → **迴圈變數降級 dynamic**；
- `t.stop()` 從 interop 直呼（`.stop()`）變**動態派發**（Dart selector `stop$0`，
  release minified 顯示 `'dz'`）；
- 執行期元素＝raw JS 物件（extension type 運行期擦除）→ 沒有 Dart selector →
  `NoSuchMethodError`；
- **首次進入僥倖不炸**（串流 null → `?.` 短路 → 空列表不迭代）；
  串流活著時迭代必炸 → 「第二次進掃描就報錯」的直接原因。
- **教訓**：interop 鏈後接 `?? const []` 是隱形地雷；空集合須**顯式型別**
  （`const <T>[]`）或用 null 檢查短路。

---

## 3. 解法演進（為什麼最終長這樣）

| 嘗試 | 做法 | 結果 | 學到什麼 |
|---|---|---|---|
| T38 看門狗 | 每秒採樣亮度，連 3 黑→停軌重取 | 自癒無效 | 前景停軌重取＝毒化，越救越黑 |
| T41 串流保活 | dispose 不停軌，重進重接**新元素** | 黑 | 元素是錨點——新元素不渲染 |
| T57 回退凍結線 | 相機碼凍結在 8596c27 基底 | ✓ 可用 | 實驗碼與穩定線**必須分離** |
| T62 生命週期 | hidden 停軌/visible 延遲 300ms 重取（**PM 研究方案**） | 背景恢復 ✓ | 系統回收路徑乾淨可行 |
| T63 幀驗證重試 | 取得後採樣驗證，黑→遞增延遲重取 | 重進仍黑 | session 已毒化，頁內重取無解 |
| T64 全程保活 | 串流＋元素全程保活，永不停軌 | 重進 ✓ 但燈不滅＋關後打不開 | 功能與直覺衝突 |
| **T65 最終** | **離開即關燈＋標記；重進整頁重載＋自動回掃描** | ✓✓ 完整 | 用 process 重啟換乾淨 context |
| T66 型別修復 | 5 處 `?? const []` → `_videoTracks()` | ✓ 無錯誤 | Dart 層自傷修復 |

---

## 4. 最終架構（T65+T66，0.5.0-pwa.20261124w）

```
進掃描頁（首次 / 重載後）
  └─ start(): 無毒化標記 → 暖機(grab+stop) → 300ms → getUserMedia
       → 掛 <video autoplay playsinline muted> → play
       → 背景驗證（採樣亮度）；黑 → 遞增延遲重取 ×4
         └─ 4 輪全敗 → 整頁重載後備（上限 2 次，防硬體故障無限迴圈）

離開掃描頁
  └─ dispose(): 停軌＋清 srcObject（**燈即滅**）
       └─ 曾有活軌 → sessionStorage['ls_scan_reopen']='1'

重進掃描頁
  └─ start(): 偵測標記 → 清標記＋設['ls_pending_scan'] → location.reload()
       └─ 乾淨 JS context（＝第一次啟動行為，PM 驗證可靠）

重載完成
  └─ AppRoot→MainShellPage postFrame: 讀['ls_pending_scan'] → 清除
       → 已引導＋未鎖定 → Navigator 自動推回掃描頁

退背景（在掃描頁時）
  └─ visibilitychange hidden: 停軌＋清 srcObject（系統本來就會回收＝乾淨）
  └─ visible: 延遲 300ms → 重取（乾淨路徑）→ 幀驗證
```

**取捨**：重進掃描頁有 2~3 秒整頁重載（閃一下載入畫面）——用「確定可用」
換「即時重用」（後者已被證明在 iOS PWA 不可靠）。

**檔案**：
- `lib/platform/scan/camera_stream_web.dart`（核心；`_videoTracks()` 型別正確迭代）
- `lib/platform/scan/camera_stream.dart`（介面：含 torch 三成員）
- `lib/platform/pending_scan_nav*.dart`（重載旗標；條件匯出隔離 web 碼）
- `lib/presentation/screens/main_shell_page.dart`（重載後自動導航）
- `lib/presentation/screens/scan/web_camera_scan.dart`（UI：補光/診斷行）

---

## 5. 工程教訓（固定規則）

1. **PWA 部署線永遠走 `pwa-accumulate` 凍結線**——鏡頭實驗碼絕不直接上 PWA
   （0.5.0 誤部署＝黑畫面復發，人為流程錯誤）。
2. **interop 鏈後禁止 `?? const []`**——空字面量推斷 `List<dynamic>` 降級型別；
   一律 null 檢查短路或顯式 `const <T>[]`。
3. **衝突清單必須全列**——本次 `head -3` 截斷 UU 清單，5 檔帶著衝突標記被
   commit（camara_stream 系列取凍結線版本補救，c82b344）。
4. **iOS PWA 相機問題先看「process 級」**——頁內任何重取手段都敵不過管線
   毒化；整頁重載是最可靠的重置手段。
5. **診斷靠重現**——minified 錯誤名（'dz'）無法靜態定位；profile build＋
   headless Chrome＋fake camera（`--use-fake-device-for-media-stream`）才能
   看到真名（'stop'）並驗證修復。
6. **每次修改前建 TODO、完成後回寫**（PM 固定要求，本輪多次受益）。

---

## 6. 驗證清單（PM 實機，0.5.0-pwa.20261124w）✅

- [x] 首次進掃描 → 相機有畫面
- [x] 離開掃描頁 → 相機燈即滅
- [x] 重進掃描頁 → 短暫重載 → 自動回掃描頁 → 相機有畫面
- [x] 背景返回 → 相機恢復
- [x] 補光（🔦）開關正常
- [x] 無 NoSuchMethodError
