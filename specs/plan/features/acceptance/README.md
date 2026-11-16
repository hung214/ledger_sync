# 驗收規格索引（Acceptance Criteria Master Index）

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.3（與 SPEC v0.3 / SDD v0.3 / BDD v0.3 對應） |
| 日期 | 2026-10-18 |
| 使用者 | PM（確認商業流程與範圍）、QA（執行驗收與記錄結果）、Dev（理解驗收標準） |
| 追溯基準 | 每個情境以 `情境編號（Fxx-Syy）` 對應 BDD.md 的 Scenario、SPEC 的 FR/AC、里程碑 M1~M7 |

---

## 1. 資料夾結構

| 檔案 | Feature | 對應需求 | 里程碑 | 情境數 |
|---|---|---|---|---|
| `F01_quick-entry.md` | 快速記帳與連續記帳 | FR-Q1~Q9 | M1 | 11 |
| `F02_transactions-accounts.md` | 交易與帳戶餘額 | FR-T、FR-A | M1/M2 | 9 |
| `F03_receipt-scan.md` | 發票掃描記帳 | FR-S1~S8 | M4 | 9 |
| `F04_credit-card-billing.md` | 信用卡預扣與帳單 | FR-C1~C8、FR-A3 | M3 | 11 |
| `F05_budget-income-goal.md` | 支出預算與收入目標 | FR-B2~B7、FR-O2 | M2 | 7 |
| `F06_recurring-transactions.md` | 定期交易（提醒確認制） | FR-T5 | M6 | 5 |
| `F07_cloud-sync-backup.md` | 雲端備份與多裝置同步 | FR-Y1~Y11 | M5/M6 | 14 |
| `F08_app-lock-security.md` | App 鎖與資料安全 | FR-X1/X3/X5 | M7 | 6 |
| `F09_data-management.md` | 資料清除與重置 | FR-O3 | M7 | 2 |
| `F10_reports-search.md` | 報表統計與搜尋 | FR-R1~R4 | M2 | 3 |
| `F12_import-andromoney.md` | 從其他 App 匯入（AndroMoney） | FR-O5 | 匯入批 | 10 |

---

## 2. 每個情境檔的固定結構

```
# 驗收規格：Fxx — Feature 名稱
├── 檔頭資訊（對應 BDD/SPEC/里程碑/優先級/所需環境）
├── 前置條件（Background 資料集 = 驗收基準資料，每情境開始前重置）
├── 情境驗收（每個 Scenario 一節）：
│   ├── 情境編號與標籤（@FR @AC @P @M）
│   ├── 測試資料（具體數值）
│   ├── 執行步驟與預期結果表（# / 操作 / 預期結果）
│   ├── 通過標準（全數符合才算 Pass）
│   ├── 失敗判定（任一成立即 Fail）
│   ├── 邊界與例外（需加測的變體）
│   └── 實例走查（具體劇本敘述，給 PM 快速理解）
└── 簽核區（QA 執行結果 + PM 複核）
```

---

## 3. 通用驗收環境

### 3.1 平台矩陣（每個 Feature 標注所需平台）

| 平台 | 最低規格 | 備註 |
|---|---|---|
| iOS | iPhone，iOS 15 | Face ID 必須（F08） |
| Android | Android 8.0，中階機（4GB RAM） | 指紋必須（F08） |
| macOS | macOS 12 | Intel 與 Apple Silicon 各一台（F10 效能） |
| Windows | Windows 10 21H2 x64 | Windows Hello（F08） |

### 3.2 測試掛鉤（對應 BDD §4）

| 掛鉤 | 用途 | 使用情境 |
|---|---|---|
| 模擬系統時間（fake clock） | 凍結/快轉裝置時間 | 結帳日、預算週期、逾期、定期交易、30 天還原 |
| 模擬雲端（in-memory adapter） | 不依賴真實雲端，可控失敗/延遲 | F07 同步、備份 |
| 通知 spy（notification spy） | 攔截並斷言通知內容與次數 | N-1~N-10 |
| 雙/三裝置模擬 | 同一帳號多裝置交錯操作 | F07 |

### 3.3 資料重置規則
- **每個情境開始前**，帳本重置為該 Feature 檔「前置條件」所述資料集；情境內產生的資料不得跨情境殘留。
- 需要跨情境連續性的（如 F07 多裝置），於該情境內自行敘明。

---

## 4. 通過 / 失敗 / 嚴重度定義

- **Pass**：該情境「執行步驟與預期結果表」全部符合，且無錯誤 log、無 crash。
- **Fail（任一即成立）**：任一預期結果不符、出現 crash、資料損毀、通知誤發/漏發（涉及通知的情境）。
- **Blocked**：前置條件無法建立（如相機故障），需註明原因。

| 嚴重度 | 定義 | 範例 |
|---|---|---|
| Blocker | 主流程無法使用或資料錯誤 | 轉帳後餘額不守恆、同步丟資料 |
| Critical | 次要流程錯誤或金額顯示錯誤 | 預算百分比算錯、帳單金額錯 |
| Major | 功能可用但體驗/文案/時序錯誤 | 通知重複發送、sticky 欄位未保留 |
| Minor | 版面、錯字、動畫瑕疵 | 進度條顏色錯誤 |

---

## 5. 簽核流程

1. QA 依情境表逐項執行並在簽核區記錄：`Pass / Fail / Blocked` + 缺陷編號。
2. 全情境通過 → PM 依「實例走查」複核商業流程 → PM 簽核。
3. 任一 Fail → 回 Dev 修復後**重新執行整份檔案**（非僅失敗情境）。
4. 簽核完成後此檔歸檔至 release 記錄（對應里程碑 M1~M7 上線條件，見 SPEC §11）。

## 6. 追溯
- 情境 ↔ Gherkin：見 `BDD.md`（v0.3）
- FR ↔ 需求條文：見 `SPEC.md` §5（v0.3）
- 設計依據：見 `SDD.md`（v0.3）
- 技術決策與開發計畫：見 `specs/plan/research.md`（v0.3，決策 D1~D14 + Sprint 計畫 + Spike 清單）
- 開發任務分解（版控/檔名/格式、Helper、migration、truth 對齊、TDD 紅綠藍燈）：見 `specs/plan/tasks.md`
- 功能修正同步矩陣（SDD/BDD/TDD/DDD）與 Debug 追蹤：見 `specs/plan/tasks.md` §7 與 `specs/plan/debug.md`
- 自動化測試 feature 檔與步驟 DSL：見 `specs/plan/tests/`（frontend/backend + dsl.md）
- UI 雛型：見 `specs/plan/ui/`（初步 HTML，畫面附 FR/AC 便利貼標註）
- API 事實（P2 草案）：見 `specs/truth/api-spec.yaml`（OpenAPI 3.1，Swagger UI 可視覺化）
- Schema 事實來源：見 `specs/truth/data-spec.dbml`（DBML，可用 DBML 插件預覽）
- 原始碼技術棧事實來源：見 `specs/truth/techstack.md`（v0.3，僅經 PR 變更）
- AC ↔ 情境總表：見 `BDD.md` §3 追溯矩陣
