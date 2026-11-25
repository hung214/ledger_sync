@FE @M7 @FR-O3 @P1
Feature: 資料清除 UI（前端自動化）
  對應: acceptance F09（呈現面）；清除執行由後端檔驗證

  Background:
    Given App 已完成首次設定
    And App 鎖已啟用（PIN 1234）
    And 帳本含 20 筆交易

  @P1 @FR-O3
  Scenario: 三重防護對話順序（未連雲端）
    Given App 未連結雲端
    When 設定→資料管理→按下「清空資料」
    And 選擇刪除範圍「全部」
    Then 顯示「將刪除所有資料且無雲端可還原」警告
    And 顯示「可先匯出備份檔」入口
    When 輸入 PIN 1234
    Then 顯示「確認文字輸入框」
    When 輸入錯誤文字「刪除」
    Then 顯示「確認文字不符」且無法繼續

  @P1 @FR-O3
  Scenario: 已連雲端加驗身分
    Given App 已連結雲端
    When 設定→資料管理→按下「清空資料」並輸入 PIN 與確認文字
    Then 顯示「重新登入雲端帳號」要求
    When 重新登入完成
    Then 顯示「已清空」並回到首次啟動引導

  @P1 @FR-O3
  Scenario: 未設定 PIN 直接進入確認文字（PM 2026-10-23）
    Given App 未連結雲端
    And App 未設定 PIN
    When 設定→資料管理→按下「清空資料」
    And 選擇刪除範圍「全部」
    Then 顯示「將刪除所有資料且無雲端可還原」警告
    When 點「下一步」
    Then 顯示「確認文字輸入框」（不經 PIN 關卡）
    And 不顯示 PIN 輸入框
