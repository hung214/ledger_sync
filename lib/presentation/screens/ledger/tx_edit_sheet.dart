import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../application/transactions/delete_transaction_use_case.dart';
import '../../../application/transactions/update_transaction_use_case.dart';
import '../../../data/sqlite/app_database.dart';
import '../quick_entry/amount_keypad.dart';
import '../quick_entry/category_picker_dialog.dart';

/// 交易編輯視窗（PM 2026-10-24：**點明細列＝編輯**；刪除鈕在編輯內）。
///
/// 欄位：金額／日期（◀▶）／帳戶／分類（彈窗）／商家／備註。
/// 金額＝**快記同款計算機鍵盤**（PM 2026-11-26：原 TextField 系統數字鍵盤→
/// 改 AmountKeypad 貼底常駐；金額欄改唯讀顯示運算式；商家／備註聚焦時隱藏
/// 計算機、失焦回來——review 頁同款互動）。
/// 動作：**刪除**（二次確認）／取消／**儲存**；支出另提供**拆分**（2 子項，FR-T6；
/// 拆分子項金額維持系統鍵盤——雙欄位不套單一計算機）。
Future<void> showTxEditSheet(
  BuildContext context,
  WidgetRef ref,
  TxRow tx, {
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TxEditSheet(tx: tx, onChanged: onChanged),
  );
}

class _TxEditSheet extends ConsumerStatefulWidget {
  const _TxEditSheet({required this.tx, required this.onChanged});

  final TxRow tx;
  final VoidCallback onChanged;

  @override
  ConsumerState<_TxEditSheet> createState() => _TxEditSheetState();
}

class _TxEditSheetState extends ConsumerState<_TxEditSheet> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _merchantCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _occurredAt;
  String? _accountId;
  String? _categoryId;

  /// 計算機運算式（快記同款；金額欄唯讀顯示，儲存＝求值結果）。
  String _expr = '';

  /// 金額欄聚焦 → **計算機由下滑入**；失焦滑出（PM 2026-11-26 全站統一）。
  final _amountFocus = FocusNode();
  bool _amountFocused = false;

  /// 文字欄位聚焦 → 計算機收起＋「完成」列（review 頁同款；系統鍵盤接手）。
  final _merchantFocus = FocusNode();
  final _noteFocus = FocusNode();
  bool _textEditing = false;

  /// 拆分模式（FR-T6）：2 子項（分類＋金額）。
  bool _splitMode = false;
  String? _splitCat0;
  String? _splitCat1;
  final _splitAmt0 = TextEditingController();
  final _splitAmt1 = TextEditingController();

  void _onAmountFocus() {
    if (mounted) setState(() => _amountFocused = _amountFocus.hasFocus);
  }

  void _onTextFocusChanged() {
    final editing = _merchantFocus.hasFocus || _noteFocus.hasFocus;
    if (editing != _textEditing && mounted) {
      setState(() => _textEditing = editing);
    }
  }

  @override
  void initState() {
    super.initState();
    final t = widget.tx;
    _amountCtrl = TextEditingController(text: '${t.amountMinor}');
    _expr = '${t.amountMinor}'; // TWD zero-decimal：amountMinor 即元
    _merchantCtrl = TextEditingController(text: t.merchant ?? '');
    _noteCtrl = TextEditingController(text: t.note ?? '');
    _occurredAt = DateTime.fromMillisecondsSinceEpoch(t.occurredAt);
    _accountId = t.accountId;
    _categoryId = t.categoryId;
    _amountFocus.addListener(_onAmountFocus);
    _merchantFocus.addListener(_onTextFocusChanged);
    _noteFocus.addListener(_onTextFocusChanged);
  }

  @override
  void dispose() {
    _amountFocus.removeListener(_onAmountFocus);
    _merchantFocus.removeListener(_onTextFocusChanged);
    _noteFocus.removeListener(_onTextFocusChanged);
    _amountFocus.dispose();
    _merchantFocus.dispose();
    _noteFocus.dispose();
    _amountCtrl.dispose();
    _merchantCtrl.dispose();
    _noteCtrl.dispose();
    _splitAmt0.dispose();
    _splitAmt1.dispose();
    super.dispose();
  }

  bool get _editable =>
      widget.tx.kind == 'expense' || widget.tx.kind == 'income';

  /// 計算機輸入（快記同款：運算式即時顯示於金額欄）。
  void _onKeypadExpr(String expr) {
    setState(() => _expr = expr);
    // 金額欄顯示原始運算式（＝ 鍵求值——PM 2026-11-26 最終版）。
    _amountCtrl.text = expr;
  }

  /// 計算機 OK 啟用（快記同款：金額即時求值 > 0）。
  bool get _saveEnabled => (AmountKeypadEvaluator.evaluate(_expr) ?? 0) > 0;

  void _save() {
    final amount = AmountKeypadEvaluator.evaluate(_expr) ?? 0;
    if (amount <= 0) return;
    UpdateTransactionUseCase(ref.read(dbProvider)).execute(
      widget.tx.id,
      amountMinor: amount,
      occurredAt: _occurredAt,
      accountId: _accountId,
      categoryId: _categoryId,
      clearCategory: _categoryId == null,
      merchant: _merchantCtrl.text.trim(),
      clearMerchant: _merchantCtrl.text.trim().isEmpty,
      note: _noteCtrl.text.trim(),
      clearNote: _noteCtrl.text.trim().isEmpty,
    );
    widget.onChanged();
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除這筆交易？'),
        content: const Text('30 天內可於「最近刪除」還原'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('tx-edit-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    DeleteTransactionUseCase(ref.read(dbProvider)).execute(widget.tx.id);
    // PM 2026-10-25：刪除後除明細外，**「最近刪除」亦須即時反映**（原僅刷新明細
    // → 該筆不會出現在最近刪除，顯示舊快取）。
    ref.invalidate(recentDeletionsProvider);
    ref.refreshAllData();
    widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  /// 拆分確認（FR-T6）：建立 2 子交易（守恆由 BE 驗證）＋刪除原交易。
  void _confirmSplit() {
    final a0 = int.tryParse(_splitAmt0.text.trim()) ?? 0;
    final a1 = int.tryParse(_splitAmt1.text.trim()) ?? 0;
    if (a0 <= 0 || a1 <= 0 || _splitCat0 == null || _splitCat1 == null) return;
    ref
        .read(saveTransactionProvider)
        .executeSplit(
          accountId: _accountId ?? widget.tx.accountId,
          totalMinor: a0 + a1,
          items: [
            (categoryId: _splitCat0, amountMinor: a0),
            (categoryId: _splitCat1, amountMinor: a1),
          ],
          occurredAt: _occurredAt,
          note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        );
    DeleteTransactionUseCase(ref.read(dbProvider)).execute(widget.tx.id);
    // 拆分同樣刪除原交易 → 一併刷新最近刪除（同上）。
    ref.invalidate(recentDeletionsProvider);
    ref.refreshAllData();
    widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickCategory({required bool split, int index = 0}) async {
    final kind = widget.tx.kind == 'income' ? 'income' : 'expense';
    final pick = await showCategoryPicker(
      context,
      ref,
      kind: kind,
      selectedId: split ? null : _categoryId,
    );
    if (pick is! CategoryPicked) return;
    setState(() {
      if (split) {
        if (index == 0) {
          _splitCat0 = pick.categoryId;
        } else {
          _splitCat1 = pick.categoryId;
        }
      } else {
        _categoryId = pick.categoryId;
      }
    });
  }

  String _catName(String? id) {
    if (id == null) return '未分類';
    return ref.read(dbProvider).categoryName(id) ?? '未分類';
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(activeAccountsProvider);
    final tf = DateFormat('yyyy/MM/dd');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '編輯交易',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        if (_editable && widget.tx.splitGroupId == null)
                          TextButton.icon(
                            key: const Key('tx-edit-split'),
                            onPressed: () {
                              // 拆分子項金額維持系統鍵盤 → 切換前先收起計算機（失焦）。
                              FocusScope.of(context).unfocus();
                              setState(() => _splitMode = !_splitMode);
                            },
                            icon: const Icon(Icons.call_split, size: 18),
                            label: Text(_splitMode ? '返回單筆' : '拆分'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (_splitMode) ...[
                      // ── 拆分模式（2 子項）──
                      for (final i in [0, 1]) ...[
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                key: Key('tx-split-$i-cat'),
                                onTap: () =>
                                    _pickCategory(split: true, index: i),
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: '分類',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  child: Text(
                                    _catName(i == 0 ? _splitCat0 : _splitCat1),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                key: Key('tx-split-$i-amount'),
                                controller: i == 0 ? _splitAmt0 : _splitAmt1,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '金額',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ] else ...[
                      // 金額＝唯讀顯示運算式；點選聚焦 → 計算機由下滑入（PM 2026-11-26）。
                      TextField(
                        key: const Key('tx-edit-amount'),
                        controller: _amountCtrl,
                        focusNode: _amountFocus,
                        readOnly: true,
                        showCursor: true,
                        keyboardType: TextInputType.none,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: const InputDecoration(
                          labelText: '金額',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          IconButton(
                            key: const Key('tx-edit-date-prev'),
                            onPressed: () => setState(
                              () => _occurredAt = _occurredAt.subtract(
                                const Duration(days: 1),
                              ),
                            ),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: TextButton(
                              key: const Key('tx-edit-date'),
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _occurredAt,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setState(
                                    () => _occurredAt = DateTime(
                                      picked.year,
                                      picked.month,
                                      picked.day,
                                      _occurredAt.hour,
                                      _occurredAt.minute,
                                    ),
                                  );
                                }
                              },
                              child: Text(
                                '${tf.format(_occurredAt)} '
                                '${DateFormat('HH:mm').format(_occurredAt)}',
                              ),
                            ),
                          ),
                          IconButton(
                            key: const Key('tx-edit-date-next'),
                            onPressed: () => setState(
                              () => _occurredAt = _occurredAt.add(
                                const Duration(days: 1),
                              ),
                            ),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                      if (_editable) ...[
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          key: const Key('tx-edit-account'),
                          initialValue: _accountId,
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: '帳戶',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final a in accounts)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(a.name),
                              ),
                          ],
                          onChanged: (v) => setState(() => _accountId = v),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          key: const Key('tx-edit-category'),
                          onTap: () => _pickCategory(split: false),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: '分類',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            child: Text(_catName(_categoryId)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const Key('tx-edit-merchant'),
                          controller: _merchantCtrl,
                          focusNode: _merchantFocus,
                          decoration: const InputDecoration(
                            labelText: '商家',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('tx-edit-note'),
                        controller: _noteCtrl,
                        focusNode: _noteFocus,
                        decoration: const InputDecoration(
                          labelText: '備註（選填）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        // 刪除鈕（PM 2026-10-24：僅在編輯內提供）。
                        TextButton.icon(
                          key: const Key('tx-edit-delete'),
                          onPressed: _delete,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('刪除'),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const Key('tx-edit-save'),
                          onPressed: _splitMode ? _confirmSplit : _save,
                          child: Text(_splitMode ? '確認拆分' : '儲存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // ── 底部固定列（PM 2026-11-26）：金額欄聚焦→計算機由下滑入、
            // 失焦滑出；文字欄聚焦→「完成」列；拆分模式不顯示（子項金額
            // 維持系統鍵盤）。
            if (!_splitMode) ...[
              const SizedBox(height: 8),
              if (_textEditing)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.shadow
                            .withValues(alpha: 0.18),
                        blurRadius: 14,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Text('輸入文字中…', style: TextStyle(fontSize: 13)),
                      const Spacer(),
                      TextButton(
                        key: const Key('tx-edit-text-done'),
                        onPressed: () => FocusScope.of(context).unfocus(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                )
              else
                FocusSlideKeypad(
                  visible: _amountFocused,
                  // 壓住小算盤向下滑 → 只收小算盤（失焦），不關編輯視窗。
                  onDragDismiss: () => FocusScope.of(context).unfocus(),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context).colorScheme.shadow
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
                ),
            ],
          ],
        ),
      ),
    );
  }
}
