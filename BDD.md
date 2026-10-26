# LedgerSync 記帳 App — 行為驅動開發規格（BDD / Gherkin）

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.3（與 SPEC v0.3 / SDD v0.3 對應） |
| 日期 | 2026-10-18 |
| 語法 | 標準 Gherkin **英文關鍵字**（Feature / Background / Scenario / Scenario Outline / Examples / Given / When / Then / And / But）；情境敘述為繁體中文，可直接被 Cucumber / flutter_gherkin 等工具鏈解析 |
| 用途 | ①自動化驗收測試（step definitions）②QA 驗收走查清單 ③需求—測試追溯 |

---

## 1. 使用說明與慣例

- **關鍵字一律使用標準英文 Gherkin**（Given-When-Then）；步驟內容以繁體中文描述，例如 `Given 帳戶「現金」餘額 2,000 元`。
- 每個場景以標籤標註：`@P0/@P1/@P2`（優先級）、`@M1~@M7`（里程碑，見 SPEC §11）、`@FR-xx`（需求）、`@AC-xx`（驗收場景）、`@offline/@sync/@desktop`（環境條件）。
- **Given** = 前置狀態與測試資料；**When** = 使用者動作或系統觸發；**Then** = 可觀察結果（UI 狀態、資料庫內容、通知）；**And/But** = 延續上一步驟語意。
- 情境檔建議置於 `test/bdd/features/*.feature`，步驟定義（step definitions）對應 SDD §5 的模組（QuickEntryController、BillingCycleService、SyncCoordinator、ReceiptPipeline 等）。
- 金額單位皆為 TWD 元；日期時間以裝置本地時區敘述。
- 「模擬系統時間」= 測試掛鉤（可凍結/快轉裝置時間），用於結帳日、預算週期、逾期判定等時間相依情境。

---

## 2. 功能情境（Feature Files）

### Feature 1：快速記帳與連續記帳（FR-Q）

```gherkin
@M1 @FR-Q
Feature: 快速記帳與連續記帳
  使用者能在 3 次點擊內記完一筆交易，並以「每筆確認」方式連續記帳。
  對應: SPEC §5.3（FR-Q1~Q9）、驗收 AC-01、AC-02

  Background:
    Given App 已完成首次設定
    And 已建立帳戶「現金」(餘額 2,000)、「示例卡」(信用卡)、「薪轉」(銀行 30,000)
    And 已建立分類「餐飲」「交通」「購物」「其他」
    And 歷史交易: 昨日 20:00 示例卡/餐飲/宵夜 120 元；本週現金/交通 5 筆

  @P0 @M1 @FR-Q4 @AC-01
  Scenario: 智慧預設_帳戶沿用上一筆_分類依時段推薦
    Given 現在是早上 8:00
    When 開啟快速記帳頁
    Then 帳戶預填為「示例卡」（上一筆所用）
    And 分類預填為上午時段（06:00–12:00）歷史最常用的支出分類
    And 時間預填為現在
    And 金額欄為空且鍵盤已聚焦

  @P0 @M1 @FR-Q4
  Scenario: 智慧預設_同商家歷史分類優先於時段規則
    Given 商家「陽光」過去 5 筆交易分類皆為「購物」
    And 目前時段歷史最常用分類為「餐飲」
    When 開啟快速記帳並輸入商家「陽光」
    Then 分類預填為「購物」

  @P0 @M1 @FR-Q4
  Scenario: 智慧預設_無任何歷史時回退預設分類
    Given 帳本沒有任何交易歷史
    When 開啟快速記帳頁
    Then 分類預填為「其他」
    And 帳戶預填為第一個未封存帳戶

  @P0 @M1 @FR-Q4
  Scenario: 關閉智慧預設_改為固定預設
    Given 設定頁已關閉「智慧預設」
    And 固定預設設定為 帳戶=現金、分類=交通
    When 開啟快速記帳頁
    Then 帳戶預填為「現金」且分類預填為「交通」
    And 不受歷史交易影響

  @P0 @M1 @FR-Q8
  Scenario: 快記頁可修改時間
    When 開啟快速記帳頁並點擊時間欄位
    Then 彈出日期時間選擇器且不離開快記頁
    When 選擇昨天 18:30 並輸入金額 200 儲存
    Then 該筆交易 occurred_at = 昨天 18:30

  @P0 @M1 @FR-Q2 @AC-01
  Scenario: 儲存後彈出確認對話框_顯示連記筆數與三個動作
    Given 快記頁已輸入金額 120、帳戶=現金、分類=餐飲
    When 按下「儲存」
    Then 交易入庫耗時 < 300ms
    And 彈出對話框「繼續記下一筆？」
    And 對話框顯示「本次已記 1 筆」
    And 對話框提供「繼續」「復原上一筆」「完成」三個動作

  @P0 @M1 @FR-Q2 @FR-Q5 @AC-02
  Scenario: 連續記帳_sticky欄位保留_金額與時間重設
    Given 已儲存 1 筆（帳戶=現金、分類=餐飲、商家=晨光早餐店）並於對話框按「繼續」
    Then 帳戶仍為「現金」、分類仍為「餐飲」、商家仍為「晨光早餐店」
    And 金額欄已清空、時間重設為現在
    And 連記計數顯示 2

  @P0 @M1 @FR-Q3
  Scenario: 復原上一筆
    Given 已於本 session 儲存 2 筆交易
    When 於確認對話框按「復原上一筆」
    Then 最後一筆交易從明細消失（軟刪除）
    And 連記計數變為 1
    And 帳戶餘額回到復原前狀態

  @P0 @M1 @FR-Q2 @AC-02
  Scenario: 完成後離開回原畫面
    Given 已連續記錄 3 筆
    When 按下「完成」
    Then 離開快記頁並回到進入前畫面
    And 明細頁即時顯示該 3 筆
    And 離開後不再提供「復原上一筆」

  @P0 @M1 @FR-Q6 @offline
  Scenario: 完全離線仍可連續記帳
    Given 裝置處於飛航模式
    When 連續記錄 2 筆支出
    Then 兩筆皆成功入庫至本地資料庫
    And 每筆皆寫入同步日誌（OpLog）待上傳

  @P1 @M2 @FR-Q7 @desktop
  Scenario: 桌面版快捷鍵開啟快記
    Given 使用者位於 Windows/macOS 版總覽頁
    When 按下 Ctrl+N（macOS 為 ⌘N）
    Then 快速記帳面板取得焦點且可直接以實體鍵盤輸入金額

  @P0 @M1 @FR-T3
  Scenario: 點交易列進入編輯（刪除在編輯內）
    Given 明細頁含支出列「120 · 早餐」
    When 點擊該交易列
    Then 開啟編輯視窗（金額/日期/帳戶/分類/商家/備註）
    And 提供「刪除」與「拆分」按鈕（均在編輯視窗內）
    When 修改金額為 150 並按「儲存」
    Then 交易金額更新為 150 且明細即時反映

  @P1 @M1 @FR-R1
  Scenario: 明細以月份為單位
    Given 本月與上月均有交易
    When 開啟明細頁
    Then 預設顯示本月交易（月份列：◀ 期間 ▾ ▶）
    When 點 ◀ 或選擇上月
    Then 顯示上月交易；亦可選「自訂區間…」或「全部月份」

  @P0 @M1 @FR-Q4
  Scenario: 快記模式列僅支出收入轉帳
    When 開啟快速記帳頁
    Then 模式列顯示「支出」「收入」「轉帳」三個選項
    And 沒有「拆分」與「預算」選項

  @P0 @M1 @FR-Q4
  Scenario: 支出與收入的類別各自獨立
    Given 支出分類集與收入分類集不同
    When 於快記切換至「收入」
    Then 三欄分類格改列收入分類
    And 分類彈窗左欄亦為收入分類

  @P0 @M1 @FR-Q4
  Scenario: 分類選擇彈窗（⭐ 常用類別／左主類別／右子類別）
    When 於快記頁點「分類」欄
    Then 彈出「選擇分類」彈窗：左欄最上方為「⭐ 常用類別」、其下主類別／右欄子類別
    When 點左欄「⭐ 常用類別」
    Then 右欄列出常用類別文字（子類別以「主類別 emoji ＋ 子類別名」呈現）
    When 點左欄「餐飲食品」再點右欄「早餐」
    Then 彈窗關閉且分類欄顯示「🍜 早餐」（子類別圖示跟隨主類別）

  @P0 @M1 @FR-Q4
  Scenario: 選子分類帶入上次金額與參數
    Given 「早餐」子分類上次記過 150 元／現金／早餐店
    When 於快記頁選「早餐」
    Then 金額預填 150、帳戶預填 現金、商家預填 早餐店
    And 時間預填 現在（不沿用上次時間）

  @P1 @M1 @FR-T7
  Scenario: 備註欄位寫入
    When 於快記頁輸入 120、分類 餐飲食品、備註「早餐」
    And 按下「OK 儲存」
    Then 該筆交易的備註為「早餐」
```

### Feature 2：交易與帳戶餘額（FR-T / FR-A）

> **v2 補充（PM 2026-10-24）**：明細交易列顯示**分類（含圖示；子類別取主類別圖示）／
> 帳戶／商家／備註**——**標題＝分類（含子類別名）**（PM 2026-10-26；原為商家，常態為「—」）、副標＝時分 · 帳戶[ · 商家][ · 備註][ · 標籤]、
> 左側分類圖示圓。**以月份為單位**（預設本月；可切換月份／自訂區間）。
> **點交易列 → 編輯**（金額/日期/帳戶/分類/商家/備註＋**刪除**＋**拆分**按鈕在編輯視窗內）。

```gherkin
@M1 @FR-T @FR-A
Feature: 交易記錄與帳戶餘額
  各類型交易的欄位必填驗證、轉帳守恆、刪除還原與儲值語意。
  對應: SPEC §5.1/§5.2、驗收 AC-10

  Background:
    Given 已建立帳戶 現金(1,000)、銀行(10,000)、票證卡(0)、示例卡(信用卡)
    And 已建立收入分類「薪資」與支出分類「交通」

  @P0 @M1 @FR-T7
  Scenario: 金額為必填且須大於零
    When 開啟支出記錄且金額欄為空
    Then 儲存按鈕為禁用狀態
    When 輸入金額 0
    Then 儲存按鈕仍為禁用狀態

  @P0 @M1 @FR-T7
  Scenario: 支出分類必選但有預設值
    When 開啟支出記錄且未選分類
    Then 分類欄已由智慧預設填入（見 Feature 1）
    And 使用者仍可修改分類

  @P0 @M1 @FR-T1 @AC-10
  Scenario: 轉帳守恆且不計入收支統計
    When 建立轉帳 現金 → 銀行 金額 400
    Then 現金餘額 = 600、銀行餘額 = 10,400
    And 總資產仍為 11,000
    And 本月支出統計不變、本月收入統計不變

  @P0 @M1 @FR-A5
  Scenario: 票證儲值屬轉帳語意
    When 建立「儲值」交易 票證卡 金額 500 來源=銀行
    Then 內部記為 transfer（銀行 -500、票證卡 +500）
    And 支出統計不包含此 500

  @P0 @M1 @FR-T3
  Scenario: 刪除交易為軟刪除且30天內可還原
    Given 已存在一筆支出 120 元
    When 刪除該筆交易
    Then 明細與統計立即不再顯示該筆
    And 帳戶餘額回升
    And 設定→「最近刪除」可於 30 天內還原該筆
    And 「最近刪除」可永久刪除該筆（二次確認後立即清除、無法還原）
    And 超過 30 天後該項自動清除

  @P0 @M1 @FR-T7
  Scenario: 信用卡還款欄位語意
    When 建立還款交易 來源=銀行 目標=示例卡 金額 5,000
    Then 分類欄為不適用（固定還款語意）
    And 商家預填「信用卡繳款」

  @P1 @M2 @FR-T6
  Scenario: 拆分交易總額守恆
    When 建立拆分交易 總額 1,000（餐飲 600 + 購物 400）
    Then 兩筆子交易共享 split_group_id
    And 各分類用量分別 +600 與 +400
    And 帳戶僅扣款 1,000 一次

  @P1 @M2 @FR-T4
  Scenario: 多幣別記錄換算
    When 建立支出 100 USD、匯率 32.0、帳戶=現金
    Then 交易保存原幣 100 與 fx_rate 32.0
    And 統計與餘額以 3,200 TWD 計
```

### Feature 3：發票掃描記帳（FR-S）

```gherkin
@M4 @FR-S
Feature: 發票掃描記帳
  台灣電子發票 QR 解析與紙本收據 OCR，全部本機處理，結果一律經確認清單入帳。
  對應: SPEC §5.4、驗收 AC-03

  Background:
    Given 已授權相機權限
    And 已建立帳戶 現金(1,000) 與分類「購物」「餐飲」「其他」

  @P0 @M4 @FR-S6
  Scenario: 獨立掃描入口
    When 開啟總覽頁與明細頁
    Then 兩頁皆有獨立「掃描」按鈕（與快記按鈕分離）

  @P0 @M4 @FR-S1 @FR-S2 @AC-03
  Scenario: 電子發票雙QR解析自動帶入
    When 掃描一張電子發票的左側與右側 QR code（總額 195 元、開立日為今天、賣方統編已可對照）
    Then 進入確認清單並顯示 1 張確認卡
    And 卡上預填 日期=開立日、商家=賣方名稱、總額=195
    And 右側 QR 含明細時列出品項清單

  @P0 @M4 @FR-S4 @AC-03
  Scenario: 確認卡必選分類與帳戶後入帳
    Given 確認卡已預填總額 195
    When 使用者選擇分類「購物」、帳戶「現金」並按儲存
    Then 建立支出交易（source=scan、金額 195）
    And 原圖壓縮後存為該筆附件
    And 自動跳到下一張確認卡（若有）

  @P0 @M4 @FR-S4
  Scenario: 總額必經人工檢視
    Given 確認卡總額欄為 195
    When 使用者清空總額並按儲存
    Then 儲存被擋下並提示「請確認總金額」
    And 不會產生 0 元交易

  @P0 @M4 @FR-S5
  Scenario: 低信賴欄位高亮要求確認
    Given OCR 對日期欄位的信賴度為 0.5（低於 0.7 門檻）
    When 進入確認卡
    Then 日期欄位以警示樣式高亮
    And 使用者修改或明確確認後才可儲存

  @P0 @M4 @FR-S2
  Scenario: 不支援的QR格式回退手動輸入
    When 掃描到非台灣電子發票規格的 QR code
    Then 顯示「無法辨識此發票格式」
    And 提供「手動輸入」按鈕建立空白確認卡

  @P1 @M4 @FR-S7
  Scenario: 連續掃描多張後批次確認
    When 連續掃描 3 張電子發票
    Then 掃描頁顯示「已掃 3 張」
    When 按「完成掃描」
    Then 確認清單顯示 3 張確認卡
    And 逐筆儲存後自動跳下一筆，全部完成後回明細頁

  @P0 @M4 @FR-S3 @offline
  Scenario: 離線環境下掃描與OCR可用
    Given 裝置處於飛航模式
    When 掃描電子發票 QR 並拍照紙本收據
    Then QR 解析與 OCR 皆正常完成（全本機運算）

  @P0 @M4 @FR-S6 @desktop
  Scenario: 桌面版掃描入口與快捷鍵
    Given 使用者位於 Windows/macOS 版
    When 按 Ctrl+Shift+S（macOS 為 ⌘⇧S）或點工具列掃描按鈕
    Then 若有相機裝置則開啟掃描頁
    But 若無相機裝置則導向「相簿/檔案匯入」
```

### Feature 4：信用卡預扣與帳單（FR-C）

```gherkin
@M3 @FR-C
Feature: 信用卡預扣、結帳與繳款
  刷卡先記錄（預扣）、結帳日彙總帳單、繳款從連結帳戶扣款；結帳日歸屬每卡可設定。
  對應: SPEC §5.6、驗收 AC-04、AC-11

  Background:
    Given 已建立銀行帳戶「薪轉」(餘額 50,000)
    And 已建立信用卡「卡A」: 結帳日 5 號、繳款日=結帳日+15 天、扣款帳戶=薪轉、歸屬=當天算本期
    And 已建立信用卡「卡B」: 結帳日 10 號、歸屬=當天算下期、扣款帳戶=薪轉
    And 卡A 本期已預扣 3 筆共 5,000 元

  @P0 @M3 @FR-C1
  Scenario: 刷卡消費即時預扣且不影響銀行餘額
    When 以卡A 記錄支出 3,000（購物）
    Then 該筆交易 settlement_status = pending
    And 卡A「本期應付」立即 +3,000
    And 薪轉餘額仍為 50,000

  @P0 @M3 @FR-C3 @AC-04
  Scenario: 結帳日後自動產生帳單
    Given 模擬系統時間為 6 月 6 日（已過卡A 結帳日）
    When 開啟 App
    Then 自動產生卡A 帳單（期間 5/6~6/5、應繳 5,000、繳款日 6/20）
    And 該 3 筆預扣交易狀態變為 billed
    And 發出通知 N-4「卡A 本期帳單 5,000，6/20 繳款」

  @P0 @M3 @FR-C2 @AC-04
  Scenario: 結帳日當天消費_歸屬規則為當天算本期
    Given 模擬系統時間為卡A 結帳日（5 號）
    When 以卡A 刷卡 1,000
    And 到達結帳時間點後執行結算
    Then 該筆 1,000 計入本期帳單

  @P0 @M3 @FR-C2 @AC-11
  Scenario Outline: 結帳日當天消費_歸屬規則每卡可設定
    When 以卡<卡號> 於其結帳日當天刷卡 1,000
    And 執行結算
    Then 該筆 1,000 歸屬於<歸屬期>

    Examples:
      | 卡號 | 設定             | 歸屬期 |
      | 卡A  | 當天算本期(預設)  | 本期   |
      | 卡B  | 當天算下期        | 下期   |

  @P0 @M3 @FR-C4 @AC-04
  Scenario: 全額繳款從連結帳戶扣款
    Given 卡A 已產生帳單（應繳 5,000）
    When 進入帳單並選擇「全額繳款」確認
    Then 產生還款轉帳：薪轉 -5,000（餘額 45,000）
    And 帳單狀態 = 已繳
    And 卡A 未繳合計歸零

  @P0 @M3 @FR-C4
  Scenario: 部分繳款
    Given 卡A 已產生帳單（應繳 5,000）
    When 選擇「自訂金額」輸入 2,000 並確認
    Then 帳單狀態 = 部分繳、paid = 2,000、剩餘顯示 3,000
    And 薪轉餘額 -2,000

  @P0 @M3 @FR-C5
  Scenario: 繳款提醒於截止前3天與當天
    Given 卡A 帳單繳款日為 6/20 且未繳清
    When 模擬系統時間為 6/17 與 6/20 各開啟 App 一次
    Then 分別發出通知 N-5（3 天前與當天各一次，不重複）

  @P0 @M3 @FR-C6
  Scenario: 逾期帳單標示
    Given 卡A 帳單繳款日 6/20 已過且未繳清
    When 開啟 App
    Then 帳單標示「逾期」並顯示於信用卡頁首
    And 補發通知 N-6（僅一次）

  @P1 @M3 @FR-C7
  Scenario: 分期付款排程
    When 以卡A 建立分期 30,000 分 6 期、首期下月 5 號
    Then 自動產生 6 筆未來 pending 交易（每月一期、金額 5,000、標記 installment_seq）
    And 卡A 顯示「未來已承諾支出 30,000」
    When 刪除該分期計畫
    Then 尚未到期的分期交易一併移除（已結帳者保留）

  @P1 @M3 @FR-C8
  Scenario: 退款衝銷已結帳交易
    Given 卡A 某筆 1,000 已被結入本期帳單
    When 針對該筆建立退款 1,000
    Then 退款以負項計入當期帳單（應繳 -1,000）
    And refund_links 記錄原交易關聯

  @P0 @M3 @FR-A3
  Scenario: 修改結帳日僅自下一期生效
    When 將卡A 結帳日由 5 號改為 15 號
    Then 本期已進行中的週期不受影響
    And 下一期起以 15 號為結帳日
```

### Feature 5：支出預算與收入目標（FR-B）

```gherkin
@M2 @FR-B
Feature: 支出預算與收入目標
  總預算與分類預算（含信用卡預扣）、80%/100%/超支警示、收入目標達標率。
  對應: SPEC §5.5、驗收 AC-05、AC-13

  Background:
    Given 已設定 餐飲預算 8,000/月、總預算 30,000/月
    And 已設定 月收入目標 60,000
    And 本期餐飲已支出 6,500（無預扣）
    And 本月已入帳收入 62,000

  @P0 @M2 @FR-B4 @AC-05
  Scenario: 預算80%警告僅通知一次
    When 新增一筆 500 元餐飲支出（使用率達 87.5%）
    Then 發出通知 N-1（每期僅此一次）
    And 總覽橫幅顯示餐飲進度條為警示色
    When 再新增一筆 100 元餐飲支出
    Then 不重複發出 80% 通知

  @P0 @M2 @FR-B4
  Scenario: 預算100%達標與超支通知
    When 餐飲使用率達 100%（累計 8,000）
    Then 發出通知 N-2
    When 再支出 320 元（使用率 > 100%）
    Then 發出通知 N-3「餐飲已超支 320」
    And 記帳流程不被封鎖（僅警示）

  @P0 @M2 @FR-B5
  Scenario: 預算用量包含信用卡預扣
    Given 本期餐飲已支出 6,500
    When 以信用卡記錄 1,000 元餐飲（預扣）
    Then 餐飲預算用量 = 7,500
    And UI 標示其中 1,000 為「預扣」部分

  @P0 @M2 @FR-B6 @AC-13
  Scenario: 收入目標達成顯示
    When 開啟總覽頁
    Then 收入目標卡顯示 達標率 100%+ 與「已達成」標記
    And 顯示 已入帳 62,000 / 目標 60,000

  @P0 @M2 @FR-B7
  Scenario: 本月預計結餘
    When 開啟總覽頁
    Then 顯示 本月預計結餘 = 60,000 − 30,000 = 30,000
    And 顯示 實際結餘 = 62,000 − 實際支出（含預扣）

  @P0 @M2 @FR-B2
  Scenario: 自訂預算起始日
    Given 預算起始日設為 25 號
    When 模擬系統時間為 6 月 3 日
    Then 目前預算週期為 5/25 ~ 6/24
    And 用量僅統計此期間內的交易

  @P0 @M2 @FR-O2
  Scenario: 通知可逐類關閉
    Given 設定頁關閉「預算警示」通知
    When 餐飲使用率跨越 80%
    Then 不發出系統通知
    And 總覽橫幅仍顯示警示狀態
```

### Feature 6：定期交易（FR-T5 提醒確認制）

```gherkin
@M6 @FR-T5
Feature: 定期交易提醒確認
  到期採提醒確認制：推播 + 待確認清單，確認才入帳。
  對應: SPEC §5.2 FR-T5、驗收 AC-12

  Background:
    Given 已建立定期交易「房租」支出 15,000、每月 1 日、帳戶=銀行、分類=居住
    And 已建立定期交易「訂閱」支出 390、每月 5 日

  @P1 @M6 @FR-T5 @AC-12
  Scenario: 到期推播與待確認清單
    Given 模擬系統時間為 6 月 1 日
    When 開啟 App
    Then 發出通知 N-7「房租到期，金額 15,000——點擊確認入帳」
    And 明細/總覽顯示「待確認」badge（計數 1）

  @P1 @M6 @FR-T5 @AC-12
  Scenario: 確認入帳（可先修改金額）
    Given 房租已在待確認清單
    When 將金額改為 16,500 後按「確認入帳」
    Then 建立支出交易 16,500（source=recurring、日期=6/1）
    And 自動產生 7/1 的下一期提醒
    And badge 計數 -1

  @P1 @M6 @FR-T5 @AC-12
  Scenario: 本次跳過
    Given 訂閱已在待確認清單
    When 按「本次跳過」
    Then 不建立任何交易
    And 仍自動產生下期（7/5）提醒

  @P1 @M6 @FR-T5 @AC-12
  Scenario: 刪除排程
    When 於定期交易詳情按「刪除排程」並確認
    Then 待確認項消失且不再產生後續提醒

  @P1 @M6 @FR-T5
  Scenario: 同一期逾期3次未處理即暫停推播
    Given 房租 6/1 到期且使用者連續於 6/1、6/2、6/3 開啟 App 皆未處理
    Then 第 4 次起不再發出推播
    And 待確認清單仍保留該項並標示「已暫停提醒」
```

### Feature 7：雲端備份與多裝置同步（FR-Y）

```gherkin
@M5 @M6 @FR-Y @sync
Feature: 雲端備份、同步與遷移
  帳號授權式同步（無同步密碼）、OpLog 合併、LWW 衝突、備份檔遷移。
  對應: SPEC §5.7、驗收 AC-06~08、AC-14

  Background:
    Given 裝置A 與裝置B 已登入同一個 Google 帳號
    And 兩裝置皆已連結 Google Drive 同步

  @P0 @M5 @FR-Y7
  Scenario: 首次連結雲端授權流程
    When 裝置A 於設定選擇「連結 Google Drive」
    Then 導向 Google 帳號登入並請求授權（App 專屬隱藏資料夾存取）
    When 使用者同意授權
    Then 立即執行首次備份
    And 頁面顯示「建議為此帳號開啟兩步驟驗證」提示
    And 全程未要求輸入任何自訂同步密碼

  @P1 @M6 @FR-Y4 @AC-06 @offline
  Scenario: 離線記帳後自動補同步
    Given 裝置A 離線期間記錄 3 筆交易
    When 裝置A 恢復網路並觸發同步（啟動時自動 / 每筆自動模式 / 手動按鈕）
    Then 3 筆變更打包上傳成功
    When 裝置B 觸發同步
    Then 裝置B 明細出現該 3 筆
    And 兩裝置各自重算的餘額一致

  @P1 @M6 @FR-Y5 @AC-07
  Scenario: 同筆記錄雙裝置修改_LWW合併
    Given 裝置A 修改交易 X 的備註為「A 版」
    And 裝置B 離線修改交易 X 的備註為「B 版」
    When 裝置B 稍後同步（其 HLC 較新）
    Then 兩裝置的交易 X 備註皆為「B 版」
    And 裝置A 產生衝突事件並發出通知 N-8
    And 同步狀態頁可檢視被覆蓋內容「A 版」

  @P0 @M5 @FR-Y2 @AC-08
  Scenario: 新裝置還原_登入同帳號即可無需密碼
    When 裝置C 安裝 App 並選擇「從雲端還原」
    And 登入同一個 Google 帳號
    Then 讀取雲端資料並完整還原（帳戶/交易/分類/預算/附件）
    And 全程不需輸入任何同步密碼

  @P0 @M5 @FR-Y2
  Scenario: 登入不同帳號看不到資料
    When 裝置C 登入另一個 Google 帳號並選擇「從雲端還原」
    Then 顯示「此帳號沒有可還原的資料」
    And 本地資料不受影響

  @P0 @M5 @FR-Y10
  Scenario: 還原前自動保護備份
    Given 裝置A 本地已有資料
    When 執行從雲端還原
    Then 還原動作前自動建立一份本地保護備份
    And 還原失敗時可由此保護備份復原

  @P0 @M5 @FR-Y3
  Scenario: 自動備份與保留份數
    Given 備份保留份數設定為 7
    When 連續 8 天皆觸發自動備份
    Then 雲端僅保留最新 7 份，最舊一份被自動清理

  @P0 @M5 @FR-Y6 @AC-14
  Scenario Outline: 備份檔匯出與密碼保護
    When 裝置A 匯出備份檔<選項>
    And 於裝置B 匯入該檔案
    Then <匯入結果>

    Examples:
      | 選項                   | 匯入結果 |
      | 不加密(預設)           | 直接還原成功，匯出時曾提示「內含完整帳務資料請妥善保管」 |
      | 設定檔案密碼+正確密碼   | 完整還原成功 |
      | 設定檔案密碼+錯誤密碼   | 拒絕匯入且不動裝置B本地資料 |

  @P0 @M5 @FR-Y9 @offline
  Scenario: 純本地模式不出網
    Given 設定已開啟「純本地模式」
    When 正常記帳、掃描、看報表
    Then 所有功能可用
    And 網路監控顯示 App 無任何對外連線

  @P1 @M6 @FR-Y11
  Scenario: 啟動時自動執行一次同步
    Given 裝置A 有 3 筆未同步變更
    When 關閉並重新啟動 App（或回到前台）
    Then 啟動後自動執行一次同步，不受任何設定影響
    And 同步狀態頁「上次同步時間」更新為剛才
    And 待同步筆數歸零

  @P1 @M6 @FR-Y11
  Scenario: 手動同步按鈕
    Given 裝置A 已連結雲端且有未同步變更
    When 按下「立即同步」按鈕（設定→雲端與同步 / 同步狀態頁）
    Then 顯示「同步中…」狀態，完成後顯示結果回饋（成功/失敗）
    And 待同步筆數歸零

  @P1 @M6 @FR-Y11
  Scenario: 設定為每筆自動同步
    Given 同步模式設定為「每筆自動同步」
    When 儲存一筆新交易
    Then 儲存完成後立即觸發同步
    And 該筆變更於數秒內打包上傳至雲端

  @P1 @M6 @FR-Y11
  Scenario: 節能批次模式為預設
    Given 同步模式為「節能批次」（預設）
    When 連續記錄 3 筆交易後不操作
    Then 約 30 秒後批次同步一次（而非每筆各觸發一次同步）
    And 閒置 15 分鐘後再執行一次同步

  @P1 @M6 @FR-Y11
  Scenario: 行動網路下附件僅 Wi-Fi 同步
    Given 裝置A 使用行動網路且「附件僅 Wi-Fi 同步」已開啟
    When 觸發同步（任何模式）
    Then 交易資料完成同步但附件暫緩上傳
    When 裝置A 切換至 Wi-Fi 並觸發同步
    Then 暫緩的附件完成上傳
```

### Feature 8：App 鎖與資料安全（FR-X）

```gherkin
@M7 @FR-X
Feature: App 鎖與資料安全
  PIN + 生物辨識鎖定、PIN 遺忘復原、隱私遮蔽。
  對應: SPEC §5.9、驗收 AC-09

  Background:
    Given 使用者已設定 PIN（1234）與 Face ID，背景鎖定門檻 30 秒
    And App 已連結雲端帳號

  @P0 @M7 @FR-X1 @AC-09
  Scenario: 背景逾時鎖定
    When App 切至背景 31 秒後返回前景
    Then 顯示鎖定畫面
    When 使用 Face ID 成功解鎖
    Then 進入 App 且資料完整可見

  @P0 @M7 @FR-X1
  Scenario: 門檻內返回不鎖定
    When App 切至背景 10 秒後返回
    Then 不出現鎖定畫面

  @P0 @M7 @FR-X1
  Scenario: 生物辨識連續失敗退回PIN
    When Face ID 連續失敗 3 次
    Then 改為要求輸入 PIN

  @P0 @M7 @FR-X5
  Scenario: PIN遺忘_已連結雲端_重新登入帳號後重設
    When 於鎖定畫面點「忘記 PIN」
    And 重新登入同一雲端帳號完成驗證
    Then 允許設定新 PIN
    And 本地資料完整保留

  @P0 @M7 @FR-X5
  Scenario: PIN遺忘_未連結雲端_僅能重置App
    Given App 從未連結雲端
    When 於鎖定畫面點「忘記 PIN」
    Then 僅提供「重置 App」選項
    And 重置需輸入確認文字（如資料將被清空的提示句）
    And 重置後本地資料清空

  @P1 @M7 @FR-X3
  Scenario: 隱私遮蔽模式
    When 於總覽頁開啟金額遮蔽
    Then 所有金額顯示為 ●●●●
    And 開關切換即時生效
```

### Feature 9：資料管理（FR-O3）

```gherkin
@M7 @FR-O3
Feature: 資料清除與重置
  對應: SPEC §5.10

  @P1 @M7 @FR-O3
  Scenario: 清空資料_未連雲端
    Given App 未連結雲端
    When 設定→清空資料 並輸入 PIN 與確認文字
    Then 本地資料庫清空並回到首次啟動引導

  @P1 @M7 @FR-O3
  Scenario: 清空資料_已連雲端需加驗身分
    Given App 已連結雲端
    When 設定→清空資料
    Then 除 PIN 與確認文字外，另要求重新登入雲端帳號
    When 完成
    Then 本地資料清空且雲端 LedgerSync/ 資料夾一併刪除

  @P1 @M7 @FR-O3
  Scenario: 清空資料_未設定PIN_不需輸入PIN
    Given App 未設定 PIN（首次安裝從未設定）
    When 設定→清空資料
    Then 警告後直接要求輸入確認文字（不經 PIN 關卡）
    And 完成後本地資料清空
```

### Feature 10：報表與搜尋（FR-R）

> **v2（PM 2026-10-24）**：統計頁對齊原型 `11-stats.html`——月份列（◀ 期間 ▾ ▶）、
> 三卡（支出/收入/淨額）、甜甜圈＋色點圖例、月趨勢長條；**DEMO 畫廊新增「11 統計」**。


```gherkin
@M2 @FR-R
Feature: 報表統計與搜尋
  對應: SPEC §5.8

  Background:
    Given 已存在 6 月的支出: 餐飲 3 筆共 900、交通 2 筆共 400；7 月支出: 餐飲 1 筆 500

  @P0 @M2 @FR-R2
  Scenario: 分類占比與趨勢
    When 開啟統計頁選擇 6 月
    Then 分類占比顯示 餐飲 900 (69.2%)、交通 400 (30.8%)
    And 月趨勢圖不含 7 月資料

  @P1 @M2 @FR-R3
  Scenario: 搜尋與複合篩選
    When 以 關鍵字=超商、期間=6月、分類=餐飲 篩選
    Then 僅顯示同時符合三條件的交易

  @P1 @M2 @FR-R4
  Scenario: CSV匯出相容Excel中文
    When 匯出 6 月交易 CSV
    Then 檔案為 UTF-8 with BOM
    And 以 Excel 開啟中文欄位不亂碼
```

---

### Feature 11：帳戶與分類設定（FR-A7 / FR-B1 / FR-O1；M8）

> 缺口來源（2026-10-22 PM 走查）：帳戶「是否合併計算」屬性與帳戶/分類設定頁
> **未實作**（分類設定雛型 `ui/09-category-settings.html` 早已存在）；外觀
> 主題（FR-O1）亦無 App 內切換。本 Feature 為補齊之規格。

```gherkin
@M8 @FR-A7 @FR-B1 @FR-O1
Feature: 設定—帳戶管理、分類管理與外觀
  對應: SPEC §5.1 FR-A2/A6/A7、§5.5 FR-B1、§5.10 FR-O1；SDD §5.6/§8

  Background:
    Given App 已完成首次設定
    And 內建預設帳戶「現金」與分類集

  @P0 @FR-A7 @FR-A2
  Scenario: 新增帳戶（含是否計入合併統計）
    When 設定→帳戶管理→新增帳戶「緊急金」類型 銀行、期初 5,000、不計入合併統計
    Then 帳戶列表顯示「緊急金（銀行）」
    And 帳戶值 5,000 標示為「不計入合併」

  @P0 @FR-A6 @FR-A2
  Scenario: 不計入合併統計不列入總覽合計
    Given 帳戶「現金」餘額 1,000、帳戶「緊急金」餘額 5,000 且不計入合併統計
    When 開啟總覽
    Then 資產合計為 1,000
    And 帳戶「緊急金」餘額 5,000 仍獨立顯示

  @P0 @FR-A7 @FR-A2
  Scenario: 刪除有未結算交易的帳戶被拒絕
    Given 帳戶「示例卡」有本期未繳帳單
    When 設定→帳戶管理→刪除「示例卡」
    Then 提示「此帳戶仍有未結算交易，可改為封存」
    And 帳戶仍存在於列表

  @P0 @FR-A7 @FR-A2
  Scenario: 編輯帳戶名稱與類型即時反映
    When 設定→帳戶管理→將「現金」改名為「錢包」、類型改為 電子支付
    Then 明細帳戶列顯示「錢包」
    And 總覽帳戶卡顯示「錢包」

  @P0 @FR-B1
  Scenario: 新增分類並排序
    When 設定→分類管理→新增支出分類「寵物」、圖示 貓、顏色 紫
    And 將「寵物」拖曳至「餐飲」之前
    Then 分類列表「寵物」在「餐飲」之前
    And 快記分類快捷格依序顯示「寵物」

  @P0 @FR-B1
  Scenario: 刪除有交易引用的分類被拒絕
    Given 分類「餐飲」已有 3 筆交易
    When 設定→分類管理→刪除「餐飲」
    Then 提示「此分類已有交易引用，可改為封存或改用其他分類」
    And 分類仍存在

  @P1 @FR-B1
  Scenario: 一層子分類
    When 設定→分類管理→於「餐飲」下新增子分類「早餐」
    Then 分類列表「餐飲」展開後顯示「早餐」
    And 記帳時可選擇子分類「早餐」

  @P1 @FR-B1
  Scenario: 子類別無圖示_圖示跟隨主類別
    Given 分類「餐飲」圖示 🍜、子分類「早餐」
    Then 分類管理子列「早餐」不顯示 emoji
    And 子分類編輯表單不提供圖示選項
    When 記帳時選「早餐」
    Then 分類欄顯示「🍜 早餐」（取主類別圖示）

  @P0 @FR-O1
  Scenario: 外觀切換深色立即生效並持久化
    When 設定→外觀→選擇「深色」
    Then App 立即以深色呈現
    When 關閉並重新啟動 App
    Then 外觀仍為「深色」

  @P1 @FR-B1
  Scenario: 子分類編輯即時連動其他頁面
    Given 分類「餐飲」下有子分類「早餐」
    When 設定→分類管理→編輯子分類「早餐」改名為「早午餐」、圖示改為 🍰
    Then 分類列表「餐飲」展開後顯示「早午餐」與新圖示
    And 快記分類選擇器顯示「早午餐」與新圖示（無需重新啟動）
```

---

## 2.1 平台對照（PM 2026-10-24 決策：**單一份 BDD ＋ 平台對照**）

> BDD 只描述**行為**（平台無關）；**UI 真相＝`specs/plan/ui/*.html` 雛型**。
> 場景以 `@desktop`／`@mobile` 標註適用殼層；同一行為兩平台共用即不標。
> 驗收走查時對照對應雛型（下方「明細」為例）。

| 畫面 | 手機雛型 | 桌面雛型 | 差異（同一行為） |
|---|---|---|---|
| 明細 | `02-ledger.html` | `08-desktop-shell.html` | 手機＝**分日卡片**（今天／昨天＋小計）；桌面＝**表格**（日期｜類型｜分類｜商家／對象｜帳戶｜金額，右對齊） |
| 快速記帳 | `03`／`10`（計算機） | `08`（右側常駐面板） | 手機＝全頁＋浮動計算機；桌面＝右側面板（三欄分類格＋分類欄） |
| 分類管理 | `09-category-settings.html` | 同（單欄為準） | 子類別無圖示（圖示跟隨主類別） |
| 設定／同步 | `07-settings-sync.html` | 同 | — |

切換依據：視窗寬度 **≥900px ＝ 桌面**（`MediaQuery`），單一程式碼庫（RWD）。

---

## 3. 追溯矩陣（AC ↔ Scenario）

| 驗收場景 | 對應情境（Feature # / 場景） | 標籤 |
|---|---|---|
| AC-01 | F1 / 智慧預設_帳戶沿用上一筆；F1 / 儲存後彈出確認對話框 | @FR-Q4 @FR-Q2 |
| AC-02 | F1 / 連續記帳_sticky欄位保留；F1 / 完成後離開回原畫面 | @FR-Q2 @FR-Q5 |
| AC-03 | F3 / 電子發票雙QR解析自動帶入；F3 / 確認卡必選分類與帳戶後入帳 | @FR-S1~S4 |
| AC-04 | F4 / 結帳日後自動產生帳單；F4 / 全額繳款從連結帳戶扣款 | @FR-C3 @FR-C4 |
| AC-05 | F5 / 預算80%警告僅通知一次 | @FR-B4 |
| AC-06 | F7 / 離線記帳後自動補同步 | @FR-Y4 |
| AC-07 | F7 / 同筆記錄雙裝置修改_LWW合併 | @FR-Y5 |
| AC-08 | F7 / 新裝置還原_登入同帳號即可無需密碼 | @FR-Y7 |
| AC-09 | F8 / 背景逾時鎖定 | @FR-X1 |
| AC-10 | F2 / 轉帳守恆且不計入收支統計 | @FR-T1 @FR-A5 |
| AC-11 | F4 / 結帳日當天消費_歸屬規則每卡可設定（Outline） | @FR-C2 |
| AC-12 | F6 / 到期推播與待確認清單；確認入帳；本次跳過；刪除排程 | @FR-T5 |
| AC-13 | F5 / 收入目標達成顯示；F5 / 本月預計結餘 | @FR-B6 @FR-B7 |
| AC-14 | F7 / 備份檔匯出與密碼保護（Outline） | @FR-Y6 |

通知 N-1~N-10 的觸發分散於 F5（N-1/2/3、N-10 由 P2 場景覆蓋）、F4（N-4/5/6）、F6（N-7）、F7（N-8）、備份失敗（N-9，見 SDD §9）。

---

## 4. 執行與維護規範

1. **自動化**：以 `flutter_gherkin`（或同類套件）掛接 integration_test；因使用標準英文關鍵字，step definitions 直接以英文句型註冊（如 `Given(/^已建立帳戶/)`），內文中文由正規表示式匹配；「模擬系統時間」「模擬雲端」「模擬通知」為三個必備測試掛鉤（fake clock / in-memory CloudStorageAdapter / notification spy）。
2. **CI 分級**：`@P0` 每次 PR 必跑（含 @offline 與雙裝置同步模擬）；`@P1` nightly；`@P2`（如 FR-B8 結轉、FR-S9 載具、FR-C9 回饋）於 release 前手動回歸。
3. **真機擴充**：F3 的 OCR 情境在 CI 以錄製影像回放；另依 SDD §10 以 ≥100 張真實發票做金測（準確率門檻 98%，總額欄位 100%）。
4. **撰寫規範**：關鍵字固定英文（Given/When/Then/And/But），步驟敘述固定繁體中文；新增需求的流程：SPEC 新增/修改 FR → 於本文件補對應 Scenario（帶 @FR 標籤）→ 更新 §3 追溯矩陣 → 實作 step definitions。三份文件（SPEC/SDD/BDD）以 FR/AC ID 為唯一追溯鍵。
