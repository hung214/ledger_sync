@FE @M7 @FR-X @P0
Feature: App 鎖與隱私 UI（前端自動化）
  對應: acceptance F08、AC-09（呈現面）；判定邏輯由後端檔驗證

  Background:
    Given App 已完成首次設定
    And App 鎖已啟用（PIN 1234 + Face ID、門檻 30 秒）
    And App 已連結雲端帳號

  @P0 @AC-09 @FR-X1
  Scenario: 背景逾時鎖定
    When App 切至背景 31 秒後返回
    Then 顯示「鎖定畫面」
    And 不顯示「任何金額」
    When 使用 Face ID 成功解鎖
    Then 顯示「離開前的畫面」且資料完整

  @P0 @FR-X1
  Scenario: 門檻內返回不鎖定
    When App 切至背景 10 秒後返回
    Then 不顯示「鎖定畫面」

  @P0 @FR-X1
  Scenario: 生物辨識失敗退回 PIN
    When Face ID 連續失敗 3 次
    Then 顯示「PIN 輸入鍵盤」
    When 輸入 PIN 1234
    Then 顯示「離開前的畫面」

  @P0 @FR-X5
  Scenario: PIN 遺忘_已連雲端重設流程
    Given 於鎖定畫面
    When 按下「忘記 PIN」
    And 重新登入同一雲端帳號
    Then 顯示「設定新 PIN」
    When 設定新 PIN 5678
    Then 顯示「資料完整保留」（20 筆交易）

  @P1 @FR-X3
  Scenario: 隱私遮蔽切換
    Given 使用者位於總覽頁
    When 按下 👁 遮蔽開關
    Then 金額全部顯示為 ●●●●
    When 再按一次
    Then 顯示「12,340」（原金額）
