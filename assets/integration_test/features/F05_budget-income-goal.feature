@FE @M2 @FR-B @P0
Feature: 預算與收入目標 UI（前端自動化）
  對應: acceptance F05、AC-05、AC-13（呈現面）；計算與通知由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 已建立分類「餐飲食品」「服飾美容」「交通運輸」
    And 預算「餐飲食品」金額 8,000、起始日 1
    And 已建立帳戶「現金」(餘額 2,000)

  @P0 @AC-05 @FR-B4
  Scenario: 進度條警示色
    Given 本期餐飲食品已支出 7,000
    When 開啟預算頁
    Then 顯示「7,000 / 8,000」
    And 顯示「87.5%」
    And 進度條為警示色（orange）

  @P0 @FR-B4
  Scenario: 超支紅色且不封鎖記帳
    Given 本期餐飲食品已支出 8,320
    When 開啟預算頁
    Then 進度條為警示色（red）
    And 顯示「超支 320」
    When 開啟快速記帳頁
    And 輸入金額 100
    Then 顯示「儲存」且為可點擊

  @P0 @FR-B5
  Scenario: 預扣標籤顯示
    Given 本期餐飲食品已支出 6,500
    And 本期餐飲食品含信用卡預扣 1,000
    When 開啟預算頁
    Then 顯示「預扣 1,000」標籤

  @P0 @AC-13 @FR-B6
  Scenario: 收入目標已達成標記
    Given 收入目標 60,000 且本月已入帳 62,000
    When 開啟總覽頁
    Then 顯示「已達成 103%」
    And 顯示「62,000 / 目標 60,000」

  @P0 @FR-O2
  Scenario: 關閉預算通知後橫幅仍在
    Given 設定→通知→「預算警示」= off
    And 本期餐飲食品已支出 7,200
    When 開啟總覽頁
    Then 進度條為警示色（orange）
