@FE @M5 @FR-Y @P0
Feature: 雲端同步 UI（前端自動化）
  對應: acceptance F07、AC-06~08、14（互動面）；協議正確性由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 模擬雲端為 in-memory adapter 且已連結（Google 帳號 ming@example.com）

  @P0 @FR-Y7
  Scenario: 首次連結授權流程
    Given 未連結雲端
    When 設定→雲端與同步→按下「連結 Google Drive」
    Then 顯示「Google 登入」（模擬）
    When 完成登入並同意授權
    Then 顯示「連結成功」
    And 顯示「建議為此帳號開啟兩步驟驗證」
    And 不顯示「同步密碼」

  @P0 @FR-Y11
  Scenario: 立即同步按鈕回饋
    Given 已有 3 筆未同步變更
    When 按下「立即同步」
    Then 顯示「同步中…」
    Then 顯示「已同步 3 筆變更」
    And 顯示「待同步 0 筆」

  @P0 @FR-Y11
  Scenario: 啟動時自動同步一次
    Given 已有 3 筆未同步變更
    When 關閉並重新啟動 App
    Then 顯示「上次同步 今天 09:00」
    And 顯示「待同步 0 筆」

  @P0 @AC-08 @FR-Y2
  Scenario: 新裝置還原（同帳號、無密碼）
    Given 模擬雲端已有帳本資料
    When 關閉並重新啟動 App 並選擇「從雲端還原」
    And 登入同一帳號
    Then 顯示「還原完成」（帳戶/交易/分類/預算）
    And 不顯示「輸入同步密碼」

  @P0 @FR-Y2
  Scenario: 不同帳號無資料可還原
    Given 模擬雲端已有帳本資料（帳號 A）
    When 選擇「從雲端還原」並登入帳號 B
    Then 顯示「此帳號沒有可還原的資料」

  @P0 @AC-07 @FR-Y5
  Scenario: 衝突檢視頁
    Given 同步狀態頁有 1 筆衝突事件（被覆蓋內容「A 版」）
    When 開啟同步狀態頁
    Then 顯示「1 筆衝突」
    When 按下檢視
    Then 顯示「A 版」（唯讀）
