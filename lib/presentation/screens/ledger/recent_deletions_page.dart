import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';
import '../../category_display.dart';
import '../../theme/app_theme.dart';

/// 「最近刪除」頁（FR-T3：軟刪除 30 天保留期，acceptance F02 S2.5；
/// 雛型 `specs/plan/ui/12-recent-deletions.html`）。
///
/// - 窗口以**曆日**計（刪除日＋30 曆日為可還原期；保留期屆滿不顯示，
///   實體清除由 TombstonePurgeService 排程——F07 接線）。
/// - 還原（S2.5-3）：墓標清除＋明細即時回復（RestoreTransactionUseCase）。
/// - **永久刪除**（PM 2026-10-24）：單筆 `recent-delete-purge-{id}`／
///   清空全部 `recent-delete-purge-all`——兩者皆**二次確認**後實體刪除
///   （**無法還原**；oplog 墓標保留＝同步安全，PurgeTombstoneUseCase）。
/// - 列版面（雛型 12）：**分類圖示圓**（子類別取主類別圖示）＋「分類 · 類型 金額」
///   ＋副標「刪除於 MM/dd HH:mm · 剩餘 N 天」；動作 **還原**（teal）／**永久刪除**（紅）。
/// - 入口：明細 AppBar（M1 無設定頁——整體設定屬 F07，dsl §3.3 註記）。
class RecentDeletionsPage extends ConsumerWidget {
  const RecentDeletionsPage({super.key});

  /// 軟刪除保留天數（FR-T3；與 TombstonePurgeService 對齊）。
  static const int retentionDays = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tombstones = ref.watch(recentDeletionsProvider);
    final visible =
        tombstones.where((t) => remainingDays(t.deletedAt!) > 0).toList();
    // 分類索引（圖示跟隨主類別——子類別無自身圖示；同明細頁規則）。
    final db = ref.watch(dbProvider);
    final catById = {
      for (final c in db.categoriesByKind('expense')) c.id: c,
      for (final c in db.categoriesByKind('income')) c.id: c,
    };
    // 圖示規則（PM 2026-10-25）：共用 category_display（子類別取主類別）。
    String? iconOf(String? categoryId) {
      final c = categoryId == null ? null : catById[categoryId];
      return c == null ? null : categoryEmojiOf(c, byId: catById);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('最近刪除'),
        actions: [
          // 清空全部：僅在有可清除項目時出現（PM 2026-10-24）。
          if (visible.isNotEmpty)
            IconButton(
              key: const Key('recent-delete-purge-all'),
              tooltip: '清空全部',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _purgeAll(context, ref, visible.length),
            ),
        ],
      ),
      body: visible.isEmpty
          ? const Center(child: Text('沒有最近刪除的交易'))
          : Column(children: [
              // 提示列（雛型 12）：保留期說明＋永久刪除不可逆。
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTokens.of(context).warning.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                    '🗓️ 交易刪除後可還原 $retentionDays 天；逾期自動永久清除。'
                    '「永久刪除」為立即清除、無法還原。',
                    style: TextStyle(
                        fontSize: 11, color: AppTokens.of(context).warning)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (_, i) {
                    final t = visible[i];
                    return _Row(
                      tx: t,
                      icon: iconOf(t.categoryId),
                      categoryName: t.categoryId == null
                          ? '未分類'
                          : (db.categoryName(t.categoryId!) ?? '未分類'),
                      onRestore: () {
                        ref.read(restoreTransactionProvider).execute(t.id);
                        ref.invalidate(ledgerProvider);
                        ref.invalidate(recentDeletionsProvider);
                      },
                      onPurge: () => _purgeOne(context, ref, t.id),
                    );
                  },
                ),
              ),
            ]),
    );
  }

  /// 單筆永久刪除（二次確認 → PurgeTombstoneUseCase）。
  Future<void> _purgeOne(BuildContext context, WidgetRef ref, String id) async {
    final ok = await _confirm(context,
        title: '永久刪除？', message: '此操作無法還原，刪除後不會出現在「最近刪除」。');
    if (!ok) return;
    final result = ref.read(purgeTombstoneProvider).execute(id);
    ref.invalidate(recentDeletionsProvider);
    if (context.mounted) _toast(context, '已永久刪除 ${result.purgedCount} 筆');
  }

  /// 清空全部（二次確認；對話框顯示筆數）。
  Future<void> _purgeAll(BuildContext context, WidgetRef ref, int count) async {
    final ok = await _confirm(context,
        title: '清空全部？', message: '將永久刪除 $count 筆，此操作無法還原。');
    if (!ok) return;
    final result = ref.read(purgeTombstoneProvider).executeAll();
    ref.invalidate(recentDeletionsProvider);
    if (context.mounted) _toast(context, '已永久刪除 ${result.purgedCount} 筆');
  }

  /// 二次確認對話框（永久刪除不可逆——FR-T3 增補）。
  Future<bool> _confirm(BuildContext context,
      {required String title, required String message}) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            key: const Key('recent-delete-purge-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('recent-delete-purge-confirm'),
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('永久刪除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  /// 剩餘可還原天數（曆日）：刪除日＋30 − 今天；0 即屆滿（不顯示）。
  static int remainingDays(int deletedAtMs) {
    final deleted = DateTime.fromMillisecondsSinceEpoch(deletedAtMs);
    final now = Clock.now();
    final elapsedDays = DateTime(now.year, now.month, now.day)
            .difference(DateTime(deleted.year, deleted.month, deleted.day))
            .inDays;
    return retentionDays - elapsedDays;
  }
}

/// 墓標列（雛型 12）：分類圖示圓＋「分類 · 類型 金額」＋「刪除於 … · 剩餘 N 天」
/// ＋動作 還原／永久刪除。
class _Row extends StatelessWidget {
  const _Row({
    required this.tx,
    required this.icon,
    required this.categoryName,
    required this.onRestore,
    required this.onPurge,
  });

  final TxRow tx;
  final String? icon;
  final String categoryName;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  /// 類型語意（無 toAccount 資訊——墓標列以 kind 呈現）。
  String get _kindLabel => switch (tx.kind) {
        'transfer' => '轉帳',
        'repayment' => '還款',
        'income' => '收入',
        _ => '支出',
      };

  /// 金額文字與顏色（支出紅／收入綠／轉帳・還款中性；千分位）。
  (String, Color) _amount(AppTokens tokens) {
    final n = NumberFormat('#,###').format(tx.amountMinor);
    return switch (tx.kind) {
      'income' => ('+$n', tokens.success),
      'transfer' => (n, tokens.subText),
      'repayment' => ('-$n', tokens.subText),
      _ => ('-$n', tokens.danger),
    };
  }

  /// 緊湊 TextButton 樣式（縮小內距；保留可點範圍高度）。
  ButtonStyle _compact([Color? fg]) => TextButton.styleFrom(
        foregroundColor: fg,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      );

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final (amountText, amountColor) = _amount(tokens);
    final emoji = icon ?? (tx.kind == 'transfer' ? '🔀' : '🧾');
    final deletedAt = DateTime.fromMillisecondsSinceEpoch(tx.deletedAt!);
    final remaining = RecentDeletionsPage.remainingDays(tx.deletedAt!);

    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.track,
          shape: BoxShape.circle,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 17)),
      ),
      title: Text.rich(TextSpan(children: [
        TextSpan(
            text: '$emoji $categoryName',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        TextSpan(
            text: ' · $_kindLabel ',
            style: TextStyle(fontSize: 12, color: tokens.subText)),
        TextSpan(
            text: amountText,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: amountColor)),
      ])),
      subtitle: Text(
          '${DateFormat('MM/dd HH:mm').format(deletedAt)} · 剩餘 $remaining 天',
          style: TextStyle(fontSize: 11, color: tokens.subText)),
      // 緊湊動作鈕（雛型 12：動作靠右、內文不被壓成多行）。
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          key: Key('recent-delete-restore-${tx.id}'),
          style: _compact(),
          onPressed: onRestore,
          child: const Text('還原'),
        ),
        TextButton(
          key: Key('recent-delete-purge-${tx.id}'),
          style: _compact(tokens.danger),
          onPressed: onPurge,
          child: const Text('永久刪除'),
        ),
      ]),
    );
  }
}
