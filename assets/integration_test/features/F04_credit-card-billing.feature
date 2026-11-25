@FE @M3 @FR-C @P0
Feature: 信用卡帳單 UI（前端自動化）
  對應: acceptance F04、AC-04、AC-11（呈現面）；結帳引擎由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 已建立帳戶「薪轉」(餘額 50,000)
    And 已建立帳戶「示例卡」(餘額 0)（結帳日 5 號、歸屬=當天算本期）
    And 模擬系統時間為 2026/07/06

  @P0 @AC-04 @FR-C3
  Scenario: 帳單產生後的呈現
    Given 已有 3 筆預扣交易於「示例卡」共 5,000（上一期）
    When 開啟信用卡頁
    Then 顯示「本期帳單 5,000」
    And 顯示「繳款日 7/20」

  @P0 @AC-04 @FR-C4
  Scenario: 全額繳款流程
    Given 已有 3 筆預扣交易於「示例卡」共 5,000（上一期）
    And 執行 BillingCycleService.run（「示例卡」）（經 fixture 觸發）
    When 開啟信用卡頁並按下「繳款」
    And 按下「全額繳款」
    Then 顯示「已繳」徽章
    And 帳戶「薪轉」餘額顯示為 45,000

  @P0 @FR-C4
  Scenario: 部分繳款顯示剩餘
    Given 已有 3 筆預扣交易於「示例卡」共 5,000（上一期）
    And 執行 BillingCycleService.run（「示例卡」）（經 fixture 觸發）
    When 按下「繳款」→「自訂金額」輸入 2,000 並確認
    Then 顯示「部分繳」徽章
    And 顯示「剩餘 3,000」

  @P0 @AC-11 @FR-C2
  Scenario: 歸屬規則顯示於卡片設定
    When 開啟卡片設定頁
    Then 顯示「歸屬：當天算本期」
    And 顯示「修改將於下一期生效」

  @P0 @FR-C6
  Scenario: 逾期帳單頁首標示
    Given 已有 3 筆預扣交易於「示例卡」共 5,000（上一期）
    And 執行 BillingCycleService.run（「示例卡」）（經 fixture 觸發）
    And 模擬系統時間為 2026/07/22
    When 開啟信用卡頁
    Then 顯示「逾期」徽章（頁首）
    And 顯示「v1 不計息」
