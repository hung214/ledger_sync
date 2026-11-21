@FE @M6 @FR-T5 @P1
Feature: 定期交易 UI（前端自動化）
  對應: acceptance F06、AC-12（呈現面）；排程計算由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 已建立帳戶「銀行」(餘額 50,000)
    And 已建立定期交易「房租」每月 1 日金額 15,000（提醒確認制）
    And 模擬系統時間為 2026/06/01

  @P1 @AC-12
  Scenario: 待確認 badge 與清單
    When 開啟明細頁
    Then 顯示「待確認 1」badge
    When 按下 badge
    Then 顯示「待確認清單」含「房租 15,000」

  @P1 @AC-12
  Scenario: 確認入帳（可先改金額）
    Given 待確認清單含「房租 15,000」
    When 將金額改為 16,500 並按下「確認入帳」
    Then 明細頁即時顯示該 1 筆
    And 顯示「待確認 0」badge
    And 顯示「下期 7/1 提醒」

  @P1 @AC-12
  Scenario: 本次跳過
    Given 待確認清單含「房租 15,000」
    When 按下「本次跳過」
    Then 明細頁即時顯示該 0 筆
    And 顯示「下期 7/1 提醒」

  @P1 @FR-T5
  Scenario: 逾期 3 次後標示已暫停
    Given 房租連續 3 次開啟 App 皆未處理（6/1、6/2、6/3）
    And 模擬系統時間為 2026/06/04
    When 開啟待確認清單
    Then 顯示「已暫停提醒」
