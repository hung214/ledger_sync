@FE @M2 @FR-R @P0
Feature: 報表與搜尋 UI（前端自動化）
  對應: acceptance F10（呈現面）；聚合與搜尋計算由後端檔驗證

  Background:
    Given App 已完成首次設定
    And 已存在 6 月支出: 餐飲食品 3 筆共 900、交通運輸 2 筆共 400（經 fixture）
    And 已存在 7 月支出: 餐飲食品 1 筆 500（經 fixture）
    And 其中 1 筆 6 月餐飲食品備註含「超商」

  @P0 @FR-R2
  Scenario: 分類占比與趨勢呈現
    When 開啟統計頁並選擇 6 月
    Then 顯示「餐飲食品 69.2%」
    And 顯示「交通運輸 30.8%」
    And 顯示「合計 1,300」
    And 月趨勢圖 6 月 = 1,300、7 月 = 500

  @P1 @FR-R3
  Scenario: 複合篩選互動
    When 篩選 期間=6月、分類=餐飲食品
    And 關鍵字輸入「超商」
    Then 僅顯示 1 筆（三條件交集）
    And 顯示篩選 chips 可逐一移除
    When 清除全部篩選
    Then 顯示全部 6 筆

  @P1 @FR-R4
  Scenario: CSV 匯出提示
    Given 篩選生效（期間=6月）
    When 按下「匯出 CSV」
    Then 顯示「已匯出 6 月交易（5 筆，UTF-8）」
