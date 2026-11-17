import 'package:flutter/material.dart';

/// App 內使用說明（F13；內容為 `specs/plan/user-guide.md` 精華版）。
///
/// 測試 keys：`help-page`／`help-section-<n>`。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('使用說明')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        key: const Key('help-page'),
        children: [
          _section(context, '資料安全（最重要）', [
            '資料存在**本裝置**。iPhone 的 PWA：刪除主畫面圖示或清除網站資料＝資料一起消失。',
            '定期備份：設定 → 資料管理 → 「備份到檔案」→ 產生 ledger_backup_日期.db。',
            '還原：同頁「從檔案還原」→ 選備份檔（覆蓋目前資料，需二次確認）。',
            '換機：舊機備份 → 新機還原；或兩台都登入雲端備份（見下）。',
          ]),
          _section(context, '從其他 App 匯入（AndroMoney）', [
            'AndroMoney：☰ 選單 → 工具/匯出 → CSV，匯出全部歷史。',
            '本 App：設定 → 資料管理 → 「從其他 App 匯入」→ 選 CSV。',
            '先預覽（筆數/期間/合計/將自動建立的帳戶與分類）→ 匯入 → 報告。',
            '重複匯入安全：同日期+金額+備註+帳戶的自動跳過；反悔可「取消本批匯入」。',
          ]),
          _section(context, '雲端備份（Google Drive）', [
            '需先完成一次性設定（由 App 提供者設定憑證）。',
            '設定 → 雲端備份 → 登入 Google → 自動備份＋跨裝置同步＋衝突檢視。',
            '資料存您自己的 Drive 隱藏資料夾（計您 15GB 額度）。',
          ]),
          _section(context, '掃描發票', [
            '手機：右下掃描圖示（快記 ＋ 上方）；桌面：工具列「掃描」或 ⌘⇧S。',
            '選發票照片 → 自動解析 → 確認分類與帳戶 → 入帳。',
          ]),
          _section(context, 'PWA 安裝與更新（iPhone 建議用 Safari）', [
            '安裝：開網址 → 分享 → 「加入主畫面」→ 圖示點開即是 App。',
            '更新：自動——開啟/回前景/每小時背景檢查，偵測到新版自動重載。',
            '目前版本：總覽頁尾可見（如 0.5.0-pwa.20261117）。',
            '首次載入 3–5 秒屬正常（下載程式）；之後有快取。',
          ]),
          _section(context, '常見問題', [
            'PWA 顯示舊版？→ 重新整理兩次，或刪圖示重裝。',
            '匯入後反悔？→ 匯入報告頁「取消本批匯入」。',
            '多個裝置？→ 都開雲端備份即可同步；或用備份檔搬移。',
          ]),
          const SizedBox(height: 24),
          Text('完整說明文件：specs/plan/user-guide.md（PM/開發端維護）',
              style: t.bodySmall),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<String> lines) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.titleMedium),
            const SizedBox(height: 8),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $line', style: t.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}
