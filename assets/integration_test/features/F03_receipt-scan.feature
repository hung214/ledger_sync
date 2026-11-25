@FE @M4 @FR-S @P0
Feature: 發票掃描 UI（前端自動化）
  對應: acceptance F03、AC-03（互動與呈現面）；解析與抽取由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 已建立帳戶「現金」(餘額 1,000)
    And 已建立分類「服飾美容」「餐飲食品」「其他」

  @P0 @FR-S6
  Scenario: 獨立掃描入口存在
    When 開啟總覽頁
    Then 顯示「掃描」按鈕（獨立於快記大鈕）
    When 開啟明細頁
    Then 顯示「掃描」按鈕（獨立於快記大鈕）

  @P0 @FR-S6
  Scenario: 相機權限拒絕後的引導
    Given 相機權限未授權
    When 開啟總覽頁並按下「掃描」
    Then 顯示「權限請求」
    When 拒絕權限
    Then 顯示「前往設定開啟權限」且不離開 App

  @P0 @AC-03 @FR-S4
  Scenario: 確認清單逐筆儲存自動跳下一張
    Given 掃描頁已掃 3 張標準測資發票
    When 按下「完成掃描」
    Then 顯示「確認清單（3 張）」
    When 確認第 1 張（分類=服飾美容、帳戶=現金）並按下「確認儲存」
    Then 顯示「2 / 3」
    And 明細頁即時顯示該 1 筆（帶 📷 附件標記）

  @P0 @FR-S5
  Scenario: 低信賴欄位高亮
    Given OCR 對日期欄位的信賴度為 0.5（低於 0.7 門檻）
    When 進入確認卡
    Then 顯示「請確認日期」（高亮樣式）
    When 按下「確認儲存」而未處理
    Then 顯示「請先確認高亮欄位」且不建立交易

  @P1 @FR-S7
  Scenario: 連續掃描張數顯示
    When 掃描標準測資發票（左QR+右QR）
    And 再掃描 2 張
    Then 顯示「已掃 3 張」
    And 顯示 3 個縮圖

  @P0 @FR-S6 @desktop
  Scenario: 桌面無相機導向匯入
    Given 使用者位於 Windows 版（無相機裝置）
    When 按下 Ctrl+Shift+S
    Then 導向「相簿/檔案匯入」
    When 從相簿匯入 fixture 1
    Then 顯示「確認清單（1 張）」
