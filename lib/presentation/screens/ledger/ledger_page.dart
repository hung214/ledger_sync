import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/lock/lock_fe_state.dart';
import '../../../application/providers.dart';
import '../../../application/reports/csv_exporter.dart';
import '../../../application/reports/search_service.dart';
import '../../../application/scan/scan_state.dart';
import '../../../core/clock.dart';
import '../../../data/sqlite/app_database.dart';
import '../../../domain/services/balance_calculator.dart';
import '../../category_display.dart';
import '../../theme/app_theme.dart';
import 'recent_deletions_page.dart';
import 'tx_edit_sheet.dart';
import '../recurring/recurring_queue_page.dart';
import '../scan/scan_page.dart';

/// 明細頁（FR-R3 呈現面）：未刪除交易列表＋複合篩選（期間/分類/關鍵字，
/// AND 語意＋chips 可逐一移除＋清除全部）＋匯出 CSV（FR-R4）。
/// 儲存/復原/刪除後即時刷新（AC-02）。
class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({super.key});

  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
  /// 期間（PM 2026-10-24：**以月份為單位**，預設＝本月）：
  /// `_range` 優先（自訂區間）；`_month`＝(年,月)；兩者皆 null＝全部。
  (int, int)? _month;
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    final now = Clock.now();
    _month = (now.year, now.month); // 預設顯示本月
  }

  /// 月份位移（◀▶；跨年）。
  void _shiftMonth(int delta) {
    final cur = _month ?? (Clock.now().year, Clock.now().month);
    final d = DateTime(cur.$1, cur.$2 + delta);
    setState(() {
      _month = (d.year, d.month);
      _range = null;
    });
  }
  String? _categoryFilter; // null = 全部（category id）
  String? _accountFilter; // null = 全部帳戶（P2 雛型帳戶 chips）
  String? _kindFilter; // null = 全部（expense/income/transfer；P2 篩選 chips）
  String _keyword = '';

  bool get _hasFilter =>
      _range != null ||
      _categoryFilter != null ||
      _accountFilter != null ||
      _kindFilter != null ||
      _keyword.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // 訂閱交易變化（儲存/復原/刪除後即時刷新 AC-02——快記 controller 會 invalidate）。
    ref.watch(ledgerProvider);
    final dueCount = ref.watch(recurringDueCountProvider);
    final db = ref.watch(dbProvider);
    final search = SearchService(db);
    final range = _periodRange();
    var rows = search.search(
      keyword: _keyword.isEmpty ? null : _keyword,
      startMs: range?.$1,
      endMs: range?.$2,
      categoryId: _categoryFilter,
    );
    // P2（雛型 02-ledger）：帳戶／收支性質維度（預設全部——不影響既有交集語意）。
    if (_accountFilter != null) {
      rows = rows
          .where((r) =>
              r.accountId == _accountFilter || r.toAccountId == _accountFilter)
          .toList();
    }
    if (_kindFilter != null) {
      rows = rows.where((r) => r.kind == _kindFilter).toList();
    }
    final accountById = {
      for (final a in ref.watch(activeAccountsProvider)) a.id: a,
    };
    // 附件索引（📷 標記；掃描儲存附件後 refresh——F03-FE S3）。
    final attachmentTxIds = ref.watch(attachmentTxIdsProvider);
    // 分類索引（明細列顯示 分類＋圖示；PM 2026-10-24）。
    // 圖示規則：子類別無自身圖示 → 取**主類別**圖示。
    final catById = {
      for (final c in db.categoriesByKind('expense')) c.id: c,
      for (final c in db.categoriesByKind('income')) c.id: c,
    };
    // 圖示規則（PM 2026-10-25）：共用 category_display——子類別取**主類別**、
    // 非圖示庫代碼→🏷️（與類別設定一致；修正子類別 icon='' 之空圖示）。
    String? iconOf(String? categoryId) {
      final c = categoryId == null ? null : catById[categoryId];
      return c == null ? null : categoryEmojiOf(c, byId: catById);
    }

    // 交易列建構（手機卡片／桌面表格共用；日期由分日標題承載時 showFullDate=false）。
    TxTile tileFor(TxRow r, {required bool tableLayout}) => TxTile(
          tx: r,
          accountName: accountById[r.accountId]?.name ?? '',
          toAccount:
              r.toAccountId == null ? null : accountById[r.toAccountId!],
          categoryName: r.categoryId == null
              ? '未分類'
              : (db.categoryName(r.categoryId!) ?? '未分類'),
          categoryId: r.categoryId,
          categoryIcon: iconOf(r.categoryId),
          note: r.note,
          hasAttachment: attachmentTxIds.contains(r.id),
          // 點列 → 編輯（含刪除/拆分；PM 2026-10-24）。
          onTap: () => showTxEditSheet(context, ref, r,
              onChanged: () => ref.invalidate(ledgerProvider)),
          tableLayout: tableLayout,
          showFullDate: false,
        );
    // 桌面（≥900px）＝表格（08 雛型）；手機＝分日卡片（02 雛型）。
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text('明細'),
        actions: [
          // 掃描入口（FR-S6：獨立於快記大鈕；F03 S1）。
          IconButton(
            key: const Key('scan-entry'),
            tooltip: '掃描',
            onPressed: () => openScanFlow(context, ref),
            icon: const Icon(Icons.document_scanner_outlined),
          ),
          TextButton(
            key: const Key('export-csv'),
            onPressed: () => _exportCsv(context, rows),
            child: const Text('匯出 CSV'),
          ),
          // 「最近刪除」入口（F02 S2.5-2；M1 無設定頁——整體屬 F07，dsl §3.3）。
          IconButton(
            key: const Key('ledger-recent-deletions'),
            tooltip: '最近刪除',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RecentDeletionsPage()),
            ),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          // P2（雛型 02-ledger）：帳戶 chips 橫列＋收支性質篩選 chips。
          _accountChips(context, db),
          _duePill(context, dueCount),
          _monthBar(context, db),
          _kindChips(context),
          _filterBar(context, db),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _hasFilter
                              ? Icons.search_off_outlined
                              : Icons.receipt_long_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 8),
                        Text(_hasFilter ? '無符合結果' : '尚無交易——點右下角快記第一筆'),
                      ],
                    ),
                  )
                : isDesktop
                    ? _desktopTable(context, rows, tileFor)
                    : _dayGroupedList(context, rows, tileFor),
          ),
        ],
      ),
    );
  }

  /// 分日標籤（雛型 02）：今天／昨天／MM/DD（週）。
  static const _dayWd = ['一', '二', '三', '四', '五', '六', '日'];

  String _dayLabel(DateTime day) {
    final now = Clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    final md = '${day.month}/${day.day}';
    if (diff == 0) return '今天 $md';
    if (diff == 1) return '昨天 $md';
    return '$md（${_dayWd[day.weekday - 1]}）';
  }

  /// 待確認 pill（FR-T5 呈現面；雛型 02 琥珀 pill）——定期交易提醒確認制入口。
  /// 0 亦顯示（F06-FE S2 契約：key `recurring-badge` ＋文字「待確認 N」）。
  Widget _duePill(BuildContext context, int dueCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: InkWell(
        key: const Key('recurring-badge'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RecurringQueuePage()),
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: dueCount > 0 ? const Color(0xFFFFF1D6) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Text('⏳', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            Text('待確認 $dueCount',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFB45309))),
            const Text(' — 點擊處理',
                style: TextStyle(fontSize: 11, color: Color(0xFFB45309))),
          ]),
        ),
      ),
    );
  }

  /// 分日群組（雛型 02）：今天／昨天／MM/DD（週）＋當日**小計**（淨額；轉帳不計收支）。
  Widget _dayGroupedList(BuildContext context, List<TxRow> rows,
      TxTile Function(TxRow, {required bool tableLayout}) tileFor) {
    final groups = <(DateTime, List<TxRow>)>[];
    for (final r in rows) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.occurredAt);
      final day = DateTime(d.year, d.month, d.day);
      if (groups.isNotEmpty && groups.last.$1 == day) {
        groups.last.$2.add(r);
      } else {
        groups.add((day, [r]));
      }
    }
    final tokens = AppTokens.of(context);
    final fmt = NumberFormat('#,###');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      itemCount: groups.length,
      itemBuilder: (_, i) {
        final (day, dayRows) = groups[i];
        // 小計＝當日淨額（expense 負、income 正；transfer/repayment 不計——AC-10）。
        final subtotal = dayRows.fold<int>(
            0,
            (sum, r) =>
                sum +
                (r.kind == 'expense'
                    ? -r.amountMinor
                    : r.kind == 'income'
                        ? r.amountMinor
                        : 0));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
            child: Row(children: [
              Text(_dayLabel(day),
                  key: Key('day-header-${day.millisecondsSinceEpoch}'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                  '小計 ${subtotal < 0 ? '-' : ''}${fmt.format(subtotal.abs())}',
                  style: TextStyle(fontSize: 12, color: tokens.subText)),
            ]),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
                children: [
                  for (final r in dayRows) tileFor(r, tableLayout: false)
                ]),
          ),
        ]);
      },
    );
  }

  /// 桌面表格（雛型 08）：日期｜類型｜分類｜商家／對象｜帳戶｜金額。
  Widget _desktopTable(BuildContext context, List<TxRow> rows,
      TxTile Function(TxRow, {required bool tableLayout}) tileFor) {
    final tokens = AppTokens.of(context);
    const f = [13, 12, 11, 18, 13, 11];
    Widget cell(String t, int i, {bool right = false}) => Expanded(
          flex: f[i],
          child: Text(t,
              textAlign: right ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                  fontSize: 11.5,
                  color: tokens.subText,
                  fontWeight: FontWeight.w600)),
        );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('交易明細',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: tokens.subText.withValues(alpha: 0.10),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(children: [
          const SizedBox(width: 14),
          cell('日期', 0),
          cell('類型', 1),
          cell('分類', 2),
          cell('商家／對象', 3),
          cell('帳戶', 4),
          cell('金額', 5, right: true),
          const SizedBox(width: 14),
        ]),
      ),
      Expanded(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(12)),
          ),
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) => tileFor(rows[i], tableLayout: true),
          ),
        ),
      ),
    ]);
  }

  /// 帳戶 chips 橫列（雛型 02-ledger）：名稱＋餘額（信用卡顯示「應付」）；
  /// 點選＝以該帳戶篩選（再點取消）。隱私遮蔽時金額 ●●●●。
  Widget _accountChips(BuildContext context, AppDatabase db) {
    final accounts = ref.watch(activeAccountsProvider);
    if (accounts.isEmpty) return const SizedBox.shrink();
    const calc = BalanceCalculator();
    final txs = ref.watch(ledgerProvider).map(txEntity).toList();
    final masked = ref.watch(privacyMaskedProvider);
    final fmt = NumberFormat('#,###');
    final tokens = AppTokens.of(context);
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        children: [
          for (final a in accounts) ...[
            ChoiceChip(
              key: Key('acct-chip-${a.id}'),
              label: Text(
                a.type == 'credit'
                    ? '${a.name} 應付 ${masked ? '●●●●' : fmt.format(calc.creditUnpaidTotal(card: accountEntity(a), txs: txs))}'
                    : '${a.name} ${masked ? '●●●●' : fmt.format(calc.assetBalance(account: accountEntity(a), txs: txs))}',
              ),
              selected: _accountFilter == a.id,
              selectedColor: tokens.success,
              showCheckmark: false,
              labelStyle: TextStyle(
                  fontSize: 12,
                  color: _accountFilter == a.id ? Colors.white : tokens.subText),
              side: BorderSide(
                  color: _accountFilter == a.id
                      ? tokens.success
                      : Theme.of(context).dividerColor),
              onSelected: (on) =>
                  setState(() => _accountFilter = on ? a.id : null),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// 收支性質篩選 chips（雛型 02-ledger：全部/支出/收入/轉帳）。
  Widget _kindChips(BuildContext context) {
    const kinds = <(String, String?)>[
      ('全部', null),
      ('支出', 'expense'),
      ('收入', 'income'),
      ('轉帳', 'transfer'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(
        spacing: 6,
        children: [
          for (final (label, kind) in kinds)
            FilterChip(
              key: Key('kind-chip-$label'),
              label: Text(label),
              selected: _kindFilter == kind,
              onSelected: (_) => setState(() => _kindFilter = kind),
            ),
        ],
      ),
    );
  }

  /// 月份列（PM 2026-10-24）：◀ 期間 ▾ ▶——**以月份為單位**，可切換／選區間。
  Widget _monthBar(BuildContext context, AppDatabase db) {
    final r = _range;
    final m = _month;
    final label = r != null
        ? '${DateFormat('MM/dd').format(r.start)}–${DateFormat('MM/dd').format(r.end)}'
        : (m == null ? '全部' : '${m.$1}/${m.$2.toString().padLeft(2, '0')}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(children: [
        IconButton(
          key: const Key('month-prev'),
          visualDensity: VisualDensity.compact,
          tooltip: '上個月',
          onPressed: () => _shiftMonth(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: PopupMenuButton<int>(
            key: const Key('filter-period'),
            tooltip: '期間',
            onSelected: (v) async {
              if (v == 0) {
                setState(() {
                  _month = null;
                  _range = null;
                });
                return;
              }
              if (v == -1) {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                  initialDateRange: _range,
                );
                if (picked != null) {
                  setState(() {
                    _range = picked;
                    _month = null;
                  });
                }
                return;
              }
              setState(() {
                _month = (v ~/ 100, v % 100);
                _range = null;
              });
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: Text('全部月份')),
              const PopupMenuItem(value: -1, child: Text('自訂區間…')),
              const PopupMenuDivider(),
              for (final (y, mm) in _availableMonths(db))
                PopupMenuItem(
                    value: y * 100 + mm,
                    child: Text('$y/${mm.toString().padLeft(2, '0')}')),
            ],
            child: InputDecorator(
              decoration:
                  const InputDecoration(labelText: '期間', isDense: true),
              child: Text(label),
            ),
          ),
        ),
        IconButton(
          key: const Key('month-next'),
          visualDensity: VisualDensity.compact,
          tooltip: '下個月',
          onPressed: () => _shiftMonth(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ]),
    );
  }

  Widget _filterBar(BuildContext context, AppDatabase db) {
    final chips = <Widget>[
      if (_categoryFilter != null)
        InputChip(
          key: const Key('chip-分類'),
          label: Text('分類 ${db.categoryName(_categoryFilter!) ?? ''}'),
          onDeleted: () => setState(() => _categoryFilter = null),
        ),
      if (_keyword.isNotEmpty)
        InputChip(
          key: const Key('chip-關鍵字'),
          label: Text('關鍵字 $_keyword'),
          onDeleted: () => setState(() => _keyword = ''),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              Flexible(
                child: PopupMenuButton<String>(
                  key: const Key('filter-category'),
                  tooltip: '分類',
                  onSelected: (id) => setState(() => _categoryFilter = id),
                  itemBuilder: (_) => [
                    for (final c in db.categoriesByKind('expense'))
                      PopupMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: '分類', isDense: true),
                    child: Text(_categoryFilter == null
                        ? '全部'
                        : (db.categoryName(_categoryFilter!) ?? '')),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('filter-keyword'),
                  decoration:
                      const InputDecoration(labelText: '關鍵字', isDense: true),
                  onChanged: (v) => setState(() => _keyword = v.trim()),
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty)
            Row(
              children: [
                ...chips.map((c) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: c,
                    )),
                TextButton(
                  key: const Key('filter-clear'),
                  onPressed: () => setState(() {
                    _range = null;
                    _categoryFilter = null;
                    _keyword = '';
                  }),
                  child: const Text('清除篩選'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 期間範圍（自訂區間優先；其次月份；皆無＝全部）。
  (int, int)? _periodRange() {
    final r = _range;
    if (r != null) {
      return (
        DateTime(r.start.year, r.start.month, r.start.day).millisecondsSinceEpoch,
        DateTime(r.end.year, r.end.month, r.end.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );
    }
    final m = _month;
    if (m == null) return null;
    return (
      DateTime(m.$1, m.$2).millisecondsSinceEpoch,
      DateTime(m.$1, m.$2 + 1).millisecondsSinceEpoch,
    );
  }

  /// 有交易之月份（(年,月) 降冪；期間選項；PM 2026-10-24 月份制）。
  List<(int, int)> _availableMonths(AppDatabase db) {
    final months = <(int, int)>{};
    for (final t in db.allTransactions()) {
      if (t.deletedAt != null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
      months.add((d.year, d.month));
    }
    final list = months.toList()
      ..sort((a, b) => a.$1 == b.$1 ? b.$2.compareTo(a.$2) : b.$1.compareTo(a.$1));
    return list;
  }

  void _exportCsv(BuildContext context, List<TxRow> rows) {
    final db = ref.read(dbProvider);
    final csv = CsvExporter(
      categoryName: (id) => db.categoryName(id) ?? id,
      accountName: (id) {
        final names =
            db.allAccounts().where((a) => a.id == id).map((a) => a.name).toList();
        return names.isEmpty ? id : names.first;
      },
    ).export(rows);
    // ignore: avoid_print
    print('CSV 匯出（${rows.length} 筆，UTF-8 BOM）：${csv.length} 字元');
    final m0 = _month;
    final label = _range != null
        ? '${DateFormat('yyyy/MM/dd').format(_range!.start)}–${DateFormat('yyyy/MM/dd').format(_range!.end)}'
        : (m0 == null ? '全部' : '${m0.$1}/${m0.$2.toString().padLeft(2, '0')}');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('匯出 CSV'),
        content: Text(
            '已匯出 $label交易（${NumberFormat('#,###').format(rows.length)} 筆，UTF-8）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

}

/// 交易列左側分類圖示圓（02-ledger 雛型；PM 2026-10-24）。
/// emoji 為分類圖示（**子類別 → 取主類別圖示**）或型別圖示（🏦/📲/🔀/🧾）。
class _CatCircle extends StatelessWidget {
  const _CatCircle({required this.emoji});
  final String emoji;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 17)),
    );
  }
}

/// 交易列（BDD：明細頁即時顯示該 N 筆 → 金額文字計數）。
///
/// 兩種版面（PM 2026-10-24）：手機＝02 卡片列（分日群組由頁面提供）；
/// 桌面（`tableLayout`）＝08 表格列。金額千分位＋支出紅／收入綠／轉帳中性。
class TxTile extends StatelessWidget {
  const TxTile({
    super.key,
    required this.tx,
    required this.accountName,
    this.toAccount,
    this.categoryName = '未分類',
    this.categoryId,
    this.categoryIcon,
    this.note,
    this.hasAttachment = false,
    this.onTap,
    this.tableLayout = false,
    this.showFullDate = true,
  });

  final TxRow tx;
  final String accountName;
  final AccountRow? toAccount;

  /// 分類名稱（含子分類）。
  final String categoryName;

  /// 分類 id／圖示（圖示跟隨主類別；子類別無自身圖示）。
  final String? categoryId;
  final String? categoryIcon;

  /// 備註。
  final String? note;

  /// 掃描附件標記（FR-S4 呈現面：📷）。
  final bool hasAttachment;

  /// 點列＝**編輯**（PM 2026-10-24：刪除改於編輯視窗內）。
  final VoidCallback? onTap;

  /// 桌面表格版面（08 雛型）。
  final bool tableLayout;

  /// 副標是否含完整日期（手機＝false：日期由分日標題承載）。
  final bool showFullDate;

  bool get _isTransferLike => tx.kind == 'transfer' || tx.kind == 'repayment';

  /// 類型標籤（表格「類型」欄）。
  String get _kindLabel {
    switch (tx.kind) {
      case 'transfer':
        return toAccount?.type == 'ewallet' ? '儲值' : '轉帳';
      case 'repayment':
        return '還款';
      case 'income':
        return '收入';
      default:
        return '支出';
    }
  }

  /// 型別圖示（轉帳／還款；分類圖示另由 [categoryIcon] 顯示於分類欄）。
  String get _kindEmoji {
    switch (tx.kind) {
      case 'transfer':
        return toAccount?.type == 'ewallet' ? '📲' : '🏦';
      case 'repayment':
        return '💳';
      default:
        return '';
    }
  }

  /// 語意標籤（雛型 02／08）。
  List<String> get _tags => [
        if (hasAttachment) '掃描入帳',
        if (tx.settlementStatus == 'pending') '預扣',
        if (tx.source == 'recurring') '定期',
        if (tx.kind == 'repayment') '已繳',
      ];

  String get _timeLabel {
    final t = DateTime.fromMillisecondsSinceEpoch(tx.occurredAt);
    return showFullDate
        ? DateFormat('yyyy/MM/dd HH:mm').format(t)
        : DateFormat('HH:mm').format(t);
  }

  /// 金額文字與顏色（雛型 02／08：**千分位**；支出紅／收入綠／轉帳中性；還款負號中性）。
  (String, Color?) _amountOf(BuildContext context) {
    final tokens = AppTokens.of(context);
    final n = NumberFormat('#,###').format(tx.amountMinor);
    switch (tx.kind) {
      case 'income':
        return ('+$n', tokens.success);
      case 'transfer':
        return (n, null);
      case 'repayment':
        return ('-$n', null);
      default:
        return ('-$n', tokens.danger);
    }
  }

  /// 標題＝**商家**欄位（PM 2026-10-24：不退回分類名——分類另於「分類」欄／副標）。
  /// 轉帳／還款為型別語意（無商家）。
  String get _title {
    switch (tx.kind) {
      case 'transfer':
        return toAccount?.type == 'ewallet' ? '儲值' : '轉帳';
      case 'repayment':
        return '還款';
      default:
        return (tx.merchant ?? '').isEmpty ? '—' : tx.merchant!;
    }
  }

  @override
  Widget build(BuildContext context) =>
      tableLayout ? _buildTableRow(context) : _buildCardRow(context);

  Widget _buildCardRow(BuildContext context) {
    final (amount, color) = _amountOf(context);
    final amountStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(color: color);
    if (tx.splitGroupId != null) {
      // 拆分樣式（FR-T6）：群組可辨識（「拆分 · 分類」）。
      return ListTile(
        onTap: onTap,
        leading: _CatCircle(emoji: categoryIcon ?? '🔀'),
        title: Text('拆分 · $categoryName'),
        subtitle: Text([_timeLabel, ..._tags].join(' · ')),
        trailing: Text('-${NumberFormat('#,###').format(tx.amountMinor)}',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: AppTokens.of(context).danger)),
      );
    }
    if (tx.kind == 'transfer') {
      return ListTile(
        onTap: onTap,
        leading: _CatCircle(
            emoji: toAccount?.type == 'ewallet' ? '📲' : '🏦'),
        title: Text(_title),
        subtitle: Text([
          _timeLabel,
          if (accountName.isNotEmpty) '$accountName → ${toAccount?.name ?? ''}',
          ..._tags,
        ].join(' · ')),
        trailing: Text(amount, style: amountStyle),
      );
    }
    final subtitle = [
      _timeLabel,
      if (accountName.isNotEmpty) accountName,
      if (tx.categoryId != null) categoryName,
      if ((note ?? '').isNotEmpty) note!,
      ..._tags,
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: _CatCircle(emoji: categoryIcon ?? '🧾'),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(_title)),
          if (hasAttachment) ...[
            const SizedBox(width: 4),
            const Text('📷', key: Key('tx-attachment')),
          ],
        ],
      ),
      subtitle: Text(subtitle),
      trailing: Text(amount, style: amountStyle),
    );
  }

  Widget _buildTableRow(BuildContext context) {
    final tokens = AppTokens.of(context);
    final (amount, color) = _amountOf(context);
    final t = DateTime.fromMillisecondsSinceEpoch(tx.occurredAt);
    const flexes = [13, 12, 11, 18, 13, 11];
    Widget cell(Widget child, int i) =>
        Expanded(flex: flexes[i], child: child);
    // 拆分＝「拆分」（分類另於分類欄）；轉帳/還款＝型別 emoji ＋ 標籤
    // （emoji 與標籤分開為兩個 Text——利於精確比對，也符雛型視覺）。
    final typeLabel = tx.splitGroupId != null ? '拆分' : _kindLabel;
    final catText = _isTransferLike
        ? '—'
        : (categoryIcon != null ? '$categoryIcon $categoryName' : categoryName);
    // 商家／對象（PM 2026-10-24）：＝**商家**欄位；轉帳＝帳戶→目標帳戶。
    final objText = _isTransferLike
        ? '$accountName → ${toAccount?.name ?? ''}'
        : ((tx.merchant ?? '').isEmpty ? '—' : tx.merchant!);
    return InkWell(
      key: Key('tx-row-${tx.id}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
            border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [
          cell(
              Text(DateFormat('MM/dd HH:mm').format(t),
                  style: const TextStyle(fontSize: 11.5)),
              0),
          cell(
              Row(children: [
                if (_kindEmoji.isNotEmpty) ...[
                  Text(_kindEmoji, style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 3),
                ],
                Flexible(
                    child: Text(typeLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12))),
                for (final tag in _tags) ...[
                  const SizedBox(width: 4),
                  _TxTag(label: tag),
                ],
              ]),
              1),
          cell(
              Text(catText,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
              2),
          cell(
              Row(children: [
                Flexible(
                    child: Text(objText,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600))),
                if (hasAttachment) ...[
                  const SizedBox(width: 4),
                  const Text('📷',
                      key: Key('tx-attachment'),
                      style: TextStyle(fontSize: 11)),
                ],
              ]),
              3),
          cell(
              Text(accountName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: tokens.subText)),
              4),
          cell(
              Align(
                  alignment: Alignment.centerRight,
                  child: Text(amount,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: color))),
              5),
        ]),
      ),
    );
  }
}

/// 語意標籤 chip（08 雛型：掃描入帳／預扣／定期·待確認）。
class _TxTag extends StatelessWidget {
  const _TxTag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (label) {
      '掃描入帳' => (const Color(0xFFE6F4F3), const Color(0xFF0B7A75)),
      '預扣' => (const Color(0xFFEDE4FF), const Color(0xFF6D4FC4)),
      _ => (const Color(0xFFFFF1D6), const Color(0xFFB45309)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style:
              TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}
