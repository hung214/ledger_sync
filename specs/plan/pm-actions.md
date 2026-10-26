# PM 行動清單（PM Actions）

| 項目 | 內容 |
|---|---|
| 用途 | 彙整**只有 PM（產品負責人）能處理**的外部服務申請、帳號開通、憑證提供與產品決策——開發端已備妥接線點，取得資訊即可接上 |
| 文件版本 | v0.1（2026-10-22） |
| 關聯文件 | `commercialization.md`（Google 憑證細節／付費模式）、`tasks.md` §4.2（排程）、`debug.md`（技術缺陷）、`session.md`（當前進度） |
| 對象 | PM；技術細節可轉交開發解惑 |

> **一句話總結**：本地端功能已全部完成並通過測試（單位 104 綠、FE 全回歸 10/10）；**唯一阻擋上架的是外部憑證／帳號**（Google OAuth 審核、商店開發者帳號）＋幾項產品決策。以下依優先序排列。

---

## 1. ⚠️ 最高優先：Google OAuth／Drive 憑證（阻擋「雲端同步」上線）

**為什麼卡**：使用者按「連結 Google Drive」時，Google 要確認「是哪個 App 在要權限」——這個 App 身分（OAuth Client ID）必須由您在 Google Cloud Console 建立。**一次性設定，之後不用維護**。

### 1.1 您要做的事（Google Cloud Console，約 40 分鐘＋審核等待）

| # | 動作 | 說明 | 預估 |
|---|---|---|---|
| 1 | 建立 Google Cloud 專案 | 名稱建議「LedgerSync」 | 5 分 |
| 2 | 啟用 **Google Drive API** | API 程式庫 → 搜尋 → 啟用（免費額度足夠，**不需計費**） | 5 分 |
| 3 | 設定 OAuth 同意畫面（consent screen） | User type＝**外部**；App 名稱、**支援 email**、**隱私權政策 URL**；scope 填 `https://www.googleapis.com/auth/drive.appdata` | 15 分 |
| 4 | **送交 Google 審核**（sensitive scope） | 需填用途說明＋（可能）示範影片；**審核數天～數週**。未過審前可先加「測試使用者」（≤100 帳號）內部測試 | ⚠️ 排程關鍵 |
| 5 | 建立 OAuth Client ID **×3** | ①**Android**：套件名＋SHA-1 指紋 ②**iOS**：bundle id ③**Web application**（桌面 loopback 用）：redirect URI | 15 分 |
| 6 | 把憑證交給開發 | Client ID／Secret（**勿入 git**——見 §7） | — |

**您需要的現成識別碼**（開發提供，直接填入 Console）：

| 平台 | 識別碼 |
|---|---|
| Android | 套件名 `com.ledgersync.ledger_sync`（SHA-1 待提供——產生 release keystore 後，見 §2） |
| iOS | bundle id `com.ledgersync.ledgerSync` |
| macOS／Windows（桌面） | 需建立 **Web application** client；redirect URI 由開發提供（loopback，`http://127.0.0.1:<port>`） |
| scope | `https://www.googleapis.com/auth/drive.appdata`（App 專屬隱藏資料夾——**看不到使用者的其他雲端硬碟檔案**） |

### 1.2 開發端現況（讓您知道依賴關係）

| 項目 | 狀態 |
|---|---|
| `GoogleDriveAdapter`（Drive v3＋appDataFolder 路徑映射／覆寫冪等／清單語意） | ✅ 完成＋**9 項單元測試綠** |
| `main()` 生產接線（db／附件目錄／裝置 id／雲端 provider） | ✅ 完成（**憑證未設定時優雅降級——不崩**） |
| 未設定時的 UI 提示（「雲端功能尚未設定（Google 憑證未就緒）」） | ✅ 完成 |
| `DriveApi` 真實實作（`googleapis` REST 呼叫） | ⏳ **等憑證**（介面已定，換實作即可） |
| OAuth 登入（行動 `google_sign_in`／桌面 loopback） | ⏳ **等憑證** |
| 套件追加（`googleapis`／`googleapis_auth`／`google_sign_in`）＋ techstack 版本 | ⏳ **需您簽核**（truth 先行原則） |

### 1.3 您**不需要**做的事（避免多花時間）

- ❌ 不需要「使用者帳號審核認證」——App 是使用者授權**他自己的** Google 帳號。
- ❌ 不需要 GCP 計費帳號（Drive API 免費額度遠超本 App 用量）。
- ❌ 不需要自架伺服器／後端（純 App 直連 Google，無中介伺服器）。

### 1.4 連網權限（開發端已備——供您實機驗證參考）

| 平台 | 設定 | 狀態 |
|---|---|---|
| macOS | 沙箱需 `network.client`（連外）＋`network.server`（桌面 OAuth loopback 本地監聽） | ✅ 已加入 `DebugProfile.entitlements`／`Release.entitlements` |
| Android | **release 版需 `INTERNET` 權限**（Flutter 範本只在 debug/profile 內建） | ✅ 已加入 `AndroidManifest.xml`（main） |
| iOS／Windows | 預設即可連外（HTTPS） | ✅ 無需變更 |

> 若憑證到位後某平台同步失敗，先檢查此表對應項——這是最常見的「程式沒錯但連不出去」原因。

---

## 2. 商店開發者帳號與簽章（上架必需）

| # | 項目 | 費用 | 用途 | 狀態 |
|---|---|---|---|---|
| 1 | **Apple Developer Program** | US$99／年 | iOS 上架＋macOS notarization 憑證（否則使用者開啟會被阻擋） | ☐ 需您申請 |
| 2 | **Google Play Console** | US$25 一次性 | Android 上架 | ☐ 需您申請 |
| 3 | **Android release keystore** | 免費 | Android 簽章（**丟失即無法更新 App**——請妥善備份） | ☐ 可由我產生後交您保管，或您自行產生 |

> 目前 CI 已能自動產出四平台產物，但為**未簽名**版本（ipa／exe／dmg／apk）——正式上架必須簽章。

---

## 3. 商業化（可選；需您決策後才動工）

`commercialization.md` §2 已列四種付費模式。若要變現，需您先決定模式；若選「訂閱制」，還需加開：

| 項目 | 用途 | 備註 |
|---|---|---|
| App Store 內購／Google Play 訂閱 | 兩商店訂閱 | 分開設定 |
| RevenueCat 帳號（可選） | 統一管理跨平台訂閱（最省工） | 月交易額 $2.5k 內免費 |

> 若暫不變現，可先略過——不影響上架。

---

## 4. 待您決策的產品事項

| # | 決策 | 背景 | 影響 |
|---|---|---|---|
| 1 | **首次啟動引導頁（新建/還原/匯入）** | F09 清空完成頁文案承諾「下次啟動回到首次設定（新建/還原/匯入）」，但目前首啟是**自動建立內建分類＋現金帳戶**直接進主畫面 | 是否要做獨立引導頁？（新增 UI 範圍） |
| 2 | **NFR-03 定義** | `research.md` 提到效能抽查含 NFR-03，但找不到其定義 | 效能複測少一項 |
| 3 | **acceptance F03 測資字串修正（76→77 碼）** | 對齊欄位對照表與 T-H6 金測所做的規格修正 | 需您複核後關閉 |
| 4 | **深色模式走查** | UI 統整已以 token 覆蓋（保證無硬編碼色），逐頁視覺需您確認 | 建議在下一版 Release 截圖走查 |
| 5 | 多幣別 900／`notify_enabled=off` 語意 | M2 遺留語意待確認 | 小範圍 |

---

## 5. 驗收走查（需您／QA 簽核）

| 項目 | 說明 |
|---|---|
| acceptance F08（App 鎖）／F09（資料管理）簽核區 | 空白——需實際走查後簽核 |
| F03（發票掃描）走查 | 需先補 **SP-2b 行動相機**（實機相機接線） |
| 四平台實機 | Release 產物已自動建置（GitHub Releases）；gh CLI 未安裝，需網頁下載或補裝 |

---

## 6. 需要您提供的資訊彙總（提供後我能立刻接上）

| # | 資訊 | 用途 | 從哪取得 |
|---|---|---|---|
| 1 | Google OAuth **Client ID ×3**（Android／iOS／Web） | 雲端連結（各平台） | Google Cloud Console §1.1 |
| 2 | Google OAuth **Client Secret**（Web/桌面） | 桌面 loopback 登入 | 同上 |
| 3 | **Android release keystore**（或授權我產生） | 上架簽章 | 您保管／我產生 |
| 4 | **Apple Team ID**＋簽章憑證 | iOS/macOS 簽章 | Apple Developer |
| 5 | **隱私權政策 URL**＋支援 email | OAuth 同意畫面送審必需 | 您提供網頁（我可提供文案草稿） |
| 6 | 商店 listing（App 名稱、圖示、說明） | 上架 | 我可提供草稿，您定稿 |

---

## 7. 憑證注入方式（技術；您只需知道「不要進 git」）

- **本機測試**：
  `flutter run --dart-define=GOOGLE_OAUTH_CLIENT_ID=<id> --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=<secret>`
- **CI（GitHub Actions）**：存為 GitHub Secrets，由 workflow 以 `--dart-define` 注入。
- **絕對不要** commit 到 git（已於本文件標示）；若憑證外洩，請在 Console 撤銷並重新產生。
- 未設定時 App **不會崩**，只會顯示「雲端功能尚未設定」——本地記帳功能完全不受影響。

---

## 8. 建議執行順序（PM 視角）

1. **今天**：啟動 §1.1 步驟 1-4（送審等待最久）＋§3 Google Play 帳號（數天）。
2. **本週**：§2 Apple Developer；產生 release keystore（我可代勞）。
3. **等待期**：§4 決策（尤其 #1 首次啟動引導頁）＋§5 驗收走查。
4. **憑證到位**：交給我 → 我接 DriveApi／OAuth（約 1-2 天）→ 真機端對端驗證 → 上架。
---

## 9. 2026-10-22 分類體系決策記錄（已實作）

| 決策 | 內容 | 狀態 |
|---|---|---|
| **主類別集定稿** | 支出 14：餐飲食品/服飾美容/居家生活/交通運輸/教育學習/休閒娛樂/3C通訊/圖書刊物/汽機車/醫療保健/人情交際/理財投資/其他/費用；收入 2：一般收入/投資收入 | ✅ 已播種＋truth 更新 |
| 轉帳 | 為交易類型（快記已支援支出/轉帳/拆帳模式），不需分類列 | ✅ 無需變更 |
| 主/子分類頁 | 分類管理頁改階層結構：主類別群組（可折疊）＋子分類縮排＋子分類可拖曳 | ✅ 已實作 |
| 常用類別區 | 快記分類選擇器最上方常駐「常用」：最近使用前 10 個（新→舊） | ✅ 已實作 |
| **子分類預設清單** | 已照提案播種 61 項（16 主類別全配）；**您之後可在 分類管理 頁自行調整**（新增/編輯/刪除/拖曳排序；快記選單頂部也有「＋新增分類」）——調整結果會存進您的資料（v0.4.16） | ✅ 已播種（PM 自行調整制） |
| **既有測試裝置** | 主類別集變更只影響「全新安裝」；已安裝裝置請用 設定→資料管理→清空資料 後重啟（自動以新分類集重播種） | ⚠️ 需您操作一次 |

---

## 10. 發佈流程修正（PM 2026-10-23）

> **規則：任何版本發佈（push tag）之前，必須先讓 PM 在本地預覽並親口確認。**
>
> **2026-10-26 追加：每次發行版都必須標註本次修改了什麼**——發版前於 `CHANGELOG.md`
> 新增該版區段（`## [x.y.z] - YYYY-MM-DD`＋新增／變更／修正／移除／文件同步），
> 發佈流水線會自動把它寫進 GitHub Release 說明；未填不得發版。

| 預覽形式 | 適用 | 說明 |
|---|---|---|
| **雛型 HTML**（`specs/plan/ui/*.html` 瀏覽器開啟） | 版面/流程定稿 | 改版**必同步更新雛型**（truth）——2026-10-23 補：03/10 已更新為兩層分類＋浮動計算機＋OK＋「.」＋亮/暗雙機 |
| **UI_DEMO 畫廊**（App 內，右上角切換亮/暗） | 元件風格 | 需本機可跑 App（**Xcode 已移除——暫不可用**，待重裝） |
| **實機安裝**（Releases → INSTALL.md） | 真機走查 | Android APK 最快；macOS DMG 次之 |

- 現況：v0.4.18 已先發佈未預覽（流程違規，已認）——**請以 Releases v0.4.18 實機安裝作為本次預覽**，意見回饋後我改完再發 v0.4.19。

---

## 11. 本機建置／實機驗證前置（PM 2026-10-23；Xcode 已重裝）

> **根因只有一個**：**Xcode／Apple SDK 授權未同意** → macOS 的 `xcrun` 被鎖 → 連帶
> `git`、`flutter`、`cocoapods` 全部不能用（連 `flutter analyze`／`flutter test` 都被擋，錯誤訊息就是那行 license）。
> 同意後**一次全解**。
>
> **為何突然要重新同意**（2026-10-23 實證）：`/Library/Preferences/com.apple.dt.Xcode.plist` 記載
> `IDEXcodeVersionForAgreedToGMLicense = 26.6`，而目前安裝的是 **Xcode 27.1** ——
> **Xcode 版本升級後 Apple 要求重新同意授權**（與 macOS 更新、磁碟權限無關；
> 開 Full Disk Access／隱私權限**不會**解此鎖）。

### 11.1 必做：一行解鎖（請在 Terminal 執行，需管理員密碼）

```bash
sudo xcodebuild -license accept
```

> 若 `accept` 不接受，改用互動式：`sudo xcodebuild -license` → 捲到最後輸入 `agree`。

**驗證（兩條都應正常，不再出現 license 警告）**

```bash
xcrun --find git      # 應印出 /usr/bin/git 之類路徑
flutter doctor        # Xcode 區塊應為 [✓]
```

### 11.2 若 Xcode 首次啟動要求「安裝元件」

開啟 Xcode.app 若跳 **Installing components** → 按 Install（需密碼）；或用命令列：

```bash
sudo xcodebuild -runFirstLaunch
```

（本機 `xcodebuild -checkFirstLaunchStatus` 已 exit 0 → 這步**可能已完成**。）

### 11.3 授權完成後我會執行（FE integration **逐檔**跑，不與其他 build 並行）

| 指令 | 用途 |
|---|---|
| `flutter test integration_test/features/f09_data_management_test.dart -d macos` | F09-FE **3 情境**（含新「未設定 PIN 跳過 PIN」） |
| `flutter test integration_test/features/f11_account_category_settings_test.dart -d macos` | F11-FE **12 情境**（含新「子分類編輯即時連動快記」） |
| `flutter build macos --release` | 本地部署驗證（產出 `.app`／DMG） |

### 11.4 macOS「隱私權與安全性」要允許的項目（首次執行時系統跳窗，請按允許）

| 項目 | 時機 | 怎麼允許 |
|---|---|---|
| **Gatekeeper：未簽章 App** | 首次開啟**建置產物**或下載的 DMG | **右鍵 → 打開**（或 系統設定 → 隱私權與安全性 → 「仍要打開」）；未簽章必然遇到，非錯誤 |
| **通知** | F05 預算警示首次觸發 | 允許「LedgerSync」傳送通知 |
| **本機網路／連線**（若跳窗） | 雲端同步、integration test | 允許 |
| **Xcode 元件安裝** | 首次開 Xcode | 允許（需管理員密碼） |

**不需要授權**：Google OAuth 憑證（你已決定先不接雲端登入）、Apple／Google 商店帳號（改直接下載發佈）。

### 11.5 其他環境備註

- **CocoaPods**：目前 `pod --version` 的錯誤**全部源自上面的授權**（它會呼叫 `git --version`）。
  授權後若仍出現 `ffi` 警告 → `gem pristine ffi --version 1.17.2`；再不行 → `brew reinstall cocoapods`。
- **磁碟**：根磁碟僅剩約 **14 GiB**；macOS 建置約需 2~4 GiB，若不足請先清 `~/Library/Developer/Xcode/DerivedData`。
- **暫時繞道**（僅供開發端跑 `analyze`／unit、widget test，**不能** build macOS／跑 integration test）：

  ```bash
  DEVELOPER_DIR=/Library/Developer/CommandLineTools flutter test
  ```

  （已用此法驗證：`dart analyze` 0 issues、**121 unit 全綠**。）
