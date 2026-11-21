@FE @M1 @FR-Q @P0
Feature: 快速記帳 UI（前端自動化）
  驗收快記頁的呈現與互動；智慧預設「規則計算」由後端檔驗證（dsl.md §4）。
  對應: acceptance F01、AC-01、AC-02

  Background:
    Given App 已完成首次設定
    And 已建立帳戶「現金」(餘額 2,000)
    And 已建立帳戶「示例卡」(餘額 0)
    And 已建立分類「餐飲食品」「交通運輸」「服飾美容」「其他」
    And 模擬系統時間為 2026/10/18 08:00
    And 歷史交易: 昨日 20:00 示例卡/餐飲食品/宵夜 120 元；本週上午現金/交通運輸 5 筆

  @P0 @AC-01 @FR-Q4
  Scenario: 智慧預設的 UI 預填呈現
    When 開啟快速記帳頁
    Then 帳戶預填為「示例卡」
    And 分類預填為「交通運輸」
    And 時間預填為「2026/10/18 08:00」
    And 金額欄為空且鍵盤已聚焦

  @P0 @AC-01 @FR-Q2
  Scenario: 儲存後彈出每筆確認對話框
    Given 快記頁已輸入金額 120、帳戶=現金、分類=餐飲食品
    When 按下「儲存」
    Then 交易入庫耗時 < 300ms（UI 計時）
    And 彈出對話框「繼續記下一筆？」且提供「繼續」「復原上一筆」「完成」三個動作
    And 顯示「本次已記 1 筆」

  @P0 @AC-02 @FR-Q5
  Scenario: 繼續時 Sticky 欄位保留、金額清空
    Given 已儲存 1 筆（現金/餐飲食品/晨光早餐店）並於對話框按「繼續」
    Then 帳戶預填為「現金」
    And 分類預填為「餐飲食品」
    And 商家預填為「晨光早餐店」
    And 金額欄為空
    And 時間預填為「現在」

  @P0 @AC-02 @FR-Q2
  Scenario: 完成後回到進入前畫面
    Given 使用者位於明細頁
    When 開啟快速記帳頁並連續記錄 3 筆後按下「完成」
    Then 使用者位於明細頁
    And 明細頁即時顯示該 3 筆

  @P0 @FR-Q8
  Scenario: 快記頁修改時間不離開頁面
    When 開啟快速記帳頁
    And 點擊時間欄位
    Then 顯示「日期時間選擇器」
    And 不顯示「離開快記頁」

  @P0 @FR-Q3
  Scenario: 對話框內復原上一筆
    Given 已於本 session 儲存 2 筆
    When 按下「復原上一筆」
    Then 顯示「本次已記 1 筆」
    And 明細頁即時顯示該 1 筆

  @P1 @M2 @FR-Q7 @desktop
  Scenario: 桌面版快捷鍵開啟快記
    Given 使用者位於總覽頁
    When 按下 Ctrl+N（macOS 為 ⌘N）
    Then 顯示「快速記帳面板」
    When 輸入金額 120 並按 Enter
    Then 彈出對話框「繼續記下一筆？」且提供「繼續」「復原上一筆」「完成」三個動作

  @P0 @FR-Q4
  Scenario: 空帳本開啟快記不崩潰
    Given 帳本為全新空本（無帳戶/分類/交易）
    When 開啟快速記帳頁
    Then 顯示「選擇帳戶」
    And 儲存按鈕為禁用狀態
