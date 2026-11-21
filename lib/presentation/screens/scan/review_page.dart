import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/categories/category_service.dart';
import '../../../application/providers.dart';
import '../../../application/scan/scan_defaults.dart';
import '../../../application/scan/scan_state.dart';
import '../../../core/clock.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../category_display.dart';
import '../quick_entry/amount_keypad.dart';
import '../quick_entry/category_picker_dialog.dart';
import '../quick_entry/quick_date_time_picker.dart';

/// 確認清單（FR-S4/S5）——**與快速記帳同款互動**（PM 2026-11-22）：
/// 置中大金額＋常駐計算機（OK＝確認儲存）、帳戶｜分類同一列（Sticky 帳戶）、
/// ◀▶ 日期快調＋DateTime picker、商家/備註欄、逐張自動前進。
///
/// 帳戶預設（PM 2026-11-22）：**最後一次掃描發票入帳的帳戶** → 無則
/// **第一個現金帳戶**（[resolveScanDefaultAccount]；入帳即記住，跨回合生效）。
/// 保留 FR-S5：低信賴日期高亮需「已確認」後始可入帳。
/// 全數完成清掃描暫存返回（acceptance S3.7）。
class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key, required this.items});

  /// 待確認清單（掃描結果暫存快照）。
  final List<ScannedItem> items;

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  int _index = 0;
  final _amountCtrl = TextEditingController();
  final _merchantCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  /// 計算機運算式（快記同款；受控顯示於金額欄）。
  String _expr = '';
  DateTime _date = DateTime.now();
  String? _categoryId;
  String? _accountId;

  /// 使用者選過分類 → 之後的卡片沿用（Sticky；快記同款）。
  bool _categoryTouched = false;

  /// 舊發票防呆（PM 2026-11-22 實測：民國 112 年 ibon 收據存進 2023/10 →
  /// 明細當月看不到＝誤以為「沒有儲存」）：日期距今 >90 天 → 視同需確認。
  bool _dateFar = false;
  final _confirmedFields = <String>{};
  String? _blockedMessage;

  TransactionDraft get _draft => widget.items[_index].draft;

  @override
  void initState() {
    super.initState();
    _loadCard(0);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _merchantCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// 載入第 [i] 張之預填：金額/日期/商家＝草稿值（每張重設——快記「金額每筆
  /// 重設」同款）；分類預設「其他」（acceptance S3.3；選過→Sticky）；
  /// 帳戶＝[resolveScanDefaultAccount]（首次載入；之後 Sticky 沿用）。
  void _loadCard(int i) {
    final draft = widget.items[i].draft;
    _expr = draft.totalMinor.value?.toString() ?? '';
    _amountCtrl.text = _expr;
    _date = draft.date.value ?? Clock.now();
    _merchantCtrl.text = draft.merchant.value ?? '';
    _noteCtrl.clear();
    if (!_categoryTouched || _categoryId == null) {
      final cats = ref.read(expenseCategoriesProvider);
      _categoryId = cats
              .where((c) => c.name == '其他')
              .map((c) => c.id)
              .firstOrNull ??
          (cats.isEmpty ? null : cats.first.id);
    }
    if (_accountId == null) {
      final last = ref.read(dbProvider).getSetting(kScanLastAccountKey);
      _accountId = resolveScanDefaultAccount(
          [
            for (final r in ref.read(activeAccountsProvider)) accountEntity(r)
          ],
          last);
    }
    _dateFar = draft.date.value != null &&
        Clock.now().difference(draft.date.value!).abs() >
            const Duration(days: 90);
    _confirmedFields.clear();
    _blockedMessage = null;
  }

  /// 未處理之待確認欄位（FR-S5 低信賴＋**舊日期防呆**——未點「已確認」/
  /// 未修改日期）。
  bool get _hasBlockingHighlight =>
      (_draft.date.needsReview || _dateFar) &&
      !_confirmedFields.contains('日期');

  /// 計算機輸入（快記同款：運算式即時顯示於金額欄）。
  void _onKeypadExpr(String expr) {
    setState(() {
      _expr = expr;
      _amountCtrl.text = expr;
      _blockedMessage = null;
    });
  }

  /// OK 儲存啟用（快記同款：金額即時求值 >0）。
  bool get _saveEnabled => (AmountKeypadEvaluator.evaluate(_expr) ?? 0) > 0;

  Future<void> _save() async {
    final total = AmountKeypadEvaluator.evaluate(_expr) ?? 0;
    if (total <= 0) {
      // FR-S4：不存在 0 元或空白總額交易（acceptance S3.4）。
      setState(() => _blockedMessage = '請確認總金額');
      return;
    }
    if (_hasBlockingHighlight) {
      // FR-S5：高亮欄位未處理前不可繞過（acceptance S3.5）。
      setState(() => _blockedMessage = '請先確認高亮欄位');
      return;
    }
    if (_accountId == null) {
      setState(() => _blockedMessage = '請選擇帳戶');
      return;
    }
    final merchant = _merchantCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    final result = ref.read(saveTransactionProvider).execute(
          accountId: _accountId!,
          categoryId: _categoryId,
          amountMinor: total,
          occurredAt: _date,
          merchant: merchant.isEmpty ? null : merchant,
          note: note.isEmpty ? null : note,
          source: 'scan',
        );
    // 記住本次帳戶＝下次掃描預設（PM 2026-11-22：最後一次掃描發票的帳戶）。
    ref.read(dbProvider).setSetting(kScanLastAccountKey, _accountId!);
    final photo = widget.items[_index].photoBytes;
    if (photo != null) {
      // 附件落地（FR-S4；BE S5 契約：壓縮→sha256→blobs→attachments＋oplog）。
      // P4 起為 async——await 確保附件列＋blob 皆落地後再刷新（web 為 IndexedDB）。
      await ref.read(attachmentStoreProvider).save(
            imageBytes: photo,
            transactionId: result.transactionId,
          );
      ref.read(attachmentTxIdsProvider.notifier).refresh();
    }
    ref.read(ledgerProvider.notifier).refresh();
    ref.refreshAllData();

    if (_index + 1 < widget.items.length) {
      // 自動跳下一張（acceptance S3.3-5：維持連續性；帳戶/分類 Sticky 沿用）。
      setState(() {
        _index++;
        _loadCard(_index);
      });
      return;
    }
    // 全數完成：清掃描暫存、返回（acceptance S3.7：回明細頁）。
    ref.read(scanDraftsProvider.notifier).reset();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = [
      for (final r in ref.watch(activeAccountsProvider)) accountEntity(r)
    ];
    final categories = ref.watch(expenseCategoriesProvider);
    final catById = categoryIndex(categories);
    final accountName = accounts
            .where((a) => a.id == _accountId)
            .map((a) => a.name)
            .firstOrNull ??
        '未選擇';
    final category = _categoryId == null ? null : catById[_categoryId];
    return Scaffold(
      appBar: AppBar(
        title: Text('確認清單（${widget.items.length} 張）',
            key: const Key('review-title')),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  Text('第 ${_index + 1} 張 / 共 ${widget.items.length} 張',
                      key: const Key('review-progress'),
                      style: Theme.of(context).textTheme.titleMedium),
                  // 發票資訊（商家／發票號——QR 帶入）。
                  if (_draft.merchant.value != null ||
                      _draft.invoiceNo != null) ...[
                    const SizedBox(height: 4),
                    Text(
                        '發票：${_draft.merchant.value ?? '（未辨識商家）'}'
                        '${_draft.invoiceNo != null ? ' · ${_draft.invoiceNo}' : ''}',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.outline)),
                  ],
                  // 日期（低信賴時高亮＋「已確認」——FR-S5；官方 QR 為高信賴不出現）。
                  if (_hasBlockingHighlight)
                    Container(
                      key: const Key('review-highlight-日期'),
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _confirmedFields.contains('日期')
                            ? null
                            : Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Text('請確認日期'),
                          const Spacer(),
                          if (!_confirmedFields.contains('日期'))
                            TextButton(
                              key: const Key('review-confirm-日期'),
                              onPressed: () => setState(
                                  () => _confirmedFields.add('日期')),
                              child: const Text('已確認'),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  // 金額（快記同款：**置中大字**）＋下方小字＝帳戶（Sticky）。
                  TextField(
                    key: const Key('review-total'),
                    controller: _amountCtrl,
                    keyboardType: TextInputType.none, // 常駐鍵盤（快記同款）
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                    decoration: const InputDecoration(
                        hintText: '0', border: InputBorder.none),
                    onChanged: (v) => setState(() => _expr = v),
                  ),
                  Center(
                    child: Text('帳戶：$accountName（Sticky）',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
                  const SizedBox(height: 4),
                  // 日期（快記同款：◀▶ 快調 ±1 天；點擊開 DateTime picker）。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const Key('review-date-prev'),
                          iconSize: 30,
                          tooltip: '前一天',
                          onPressed: () => setState(() {
                            _date = _date.subtract(const Duration(days: 1));
                            _confirmedFields.add('日期'); // 動過日期＝已確認
                          }),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        TextButton(
                          key: const Key('review-date'),
                          style: TextButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => QuickDateTimePicker(
                                initial: _date,
                                onSelected: (dt) => setState(() {
                                  _date = dt;
                                  _confirmedFields.add('日期');
                                }),
                              ),
                            );
                          },
                          child: Text(_dateLabel(_date),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700)),
                        ),
                        IconButton(
                          key: const Key('review-date-next'),
                          iconSize: 30,
                          tooltip: '後一天',
                          onPressed: () => setState(() {
                            _date = _date.add(const Duration(days: 1));
                            _confirmedFields.add('日期');
                          }),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 帳戶｜分類（快記同款：同一列兩欄、等高方框）。
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _pickerField(
                            key: const Key('review-account'),
                            label: '帳戶',
                            text: accountName,
                            entries: [
                              for (final a in accounts) (a.id, a.name, false)
                            ],
                            onSelected: (id) =>
                                setState(() => _accountId = id),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            key: const Key('review-category'),
                            onTap: _openCategoryPicker,
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                  labelText: '分類',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  suffixIcon: Icon(Icons.chevron_right,
                                      size: 18)),
                              child: Text(
                                  category == null
                                      ? '選擇分類'
                                      : categoryLabelOf(category,
                                          byId: catById),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('review-merchant'),
                    controller: _merchantCtrl,
                    decoration: const InputDecoration(
                        labelText: '商家', border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('review-note'),
                    controller: _noteCtrl,
                    decoration: const InputDecoration(
                        labelText: '備註（選填）', border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  if (_blockedMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        _blockedMessage!,
                        key: const Key('review-blocked'),
                        style:
                            TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
            // 浮動底部計算機（快記同款）：OK＝確認儲存，鍵盤貼底常駐。
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .shadow
                        .withValues(alpha: 0.18),
                    blurRadius: 14,
                    offset: const Offset(0, -3),
                  ),
                ],
              ),
              child: AmountKeypad(
                expr: _expr,
                onExprChanged: _onKeypadExpr,
                onOk: _save,
                okEnabled: _saveEnabled,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分類選擇彈窗（快記同款：上常用／左主／右子；＋即建即選）。
  Future<void> _openCategoryPicker() async {
    final pick = await showCategoryPicker(
      context,
      ref,
      kind: 'expense',
      selectedId: _categoryId,
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case CategoryPicked(:final categoryId):
        setState(() {
          _categoryId = categoryId;
          _categoryTouched = true;
          _blockedMessage = null;
        });
      case CategoryAddRequested(:final asSub, :final parentId):
        await _quickAddCategory(asSub: asSub, parentId: parentId);
    }
  }

  /// 分類即建即選（快記同款）。
  Future<void> _quickAddCategory(
      {required bool asSub, String? parentId}) async {
    if (asSub && parentId == null) return;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(asSub ? '新增子分類' : '新增主類別'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分類名稱'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(ctrl.text.trim()),
              child: const Text('建立')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final row =
          CategoryService(ref.read(dbProvider)).create(kind: 'expense', name: name, parentId: parentId);
      ref.invalidate(expenseCategoriesProvider);
      ref.refreshAllData();
      setState(() {
        _categoryId = row.id;
        _categoryTouched = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 日期顯示（中文星期；不依賴 intl locale 初始化——快記同款）。
  static const _weekdays = ['週一', '週二', '週三', '週四', '週五', '週六', '週日'];

  static String _dateLabel(DateTime t) =>
      '${DateFormat('MM/dd').format(t)}'
      '（${_weekdays[t.weekday - 1]}）'
      '${DateFormat('HH:mm').format(t)}';

  /// 帳戶選擇（快記同款：PopupMenuButton＋方框 InputDecorator）。
  Widget _pickerField({
    required Key key,
    required String label,
    required String text,
    required List<(String, String, bool)> entries,
    required void Function(String?) onSelected,
  }) {
    return PopupMenuButton<String>(
      key: key,
      initialValue: null,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final (id, name, _) in entries)
          PopupMenuItem(value: id, child: Text(name)),
      ],
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(text, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
