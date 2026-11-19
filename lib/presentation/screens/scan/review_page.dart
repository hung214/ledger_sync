import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../application/scan/scan_state.dart';
import '../../../core/clock.dart';
import '../../../domain/entities/transaction_draft.dart';

/// 確認清單（FR-S4/S5）：逐張確認卡——總額一律人工檢視（FR-S4：0/空擋下）、
/// 低信賴欄位高亮需「已確認」（FR-S5 0.7 門檻）、確認儲存（source=scan＋
/// 附件落地）後自動跳下一張（acceptance S3.3），全數完成返回。
class ReviewPage extends ConsumerStatefulWidget {
  const ReviewPage({super.key, required this.items});

  /// 待確認清單（掃描結果暫存快照）。
  final List<ScannedItem> items;

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  int _index = 0;
  final _totalCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  String? _categoryId;
  String? _accountId;
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
    _totalCtrl.dispose();
    _dateCtrl.dispose();
    super.dispose();
  }

  /// 載入第 [i] 張之預填（FR-S4 契約：總額/日期預填草稿值；分類預設「其他」；
  /// 帳戶預設第一個未封存——acceptance S3.3）。
  void _loadCard(int i) {
    final draft = widget.items[i].draft;
    _totalCtrl.text = draft.totalMinor.value?.toString() ?? '';
    final date = draft.date.value ?? Clock.now();
    _dateCtrl.text = DateFormat('yyyy/MM/dd').format(date);
    final cats = ref.read(expenseCategoriesProvider);
    _categoryId = cats
            .where((c) => c.name == '其他')
            .map((c) => c.id)
            .firstOrNull ??
        (cats.isEmpty ? null : cats.first.id);
    final accounts = ref.read(activeAccountsProvider);
    _accountId = accounts.isEmpty ? null : accounts.first.id;
    _confirmedFields.clear();
    _blockedMessage = null;
  }

  /// 未處理之低信賴欄位（FR-S5：<0.7 且未點「已確認」/未修改）。
  bool get _hasBlockingHighlight =>
      (_draft.date.needsReview && !_confirmedFields.contains('日期'));

  Future<void> _save() async {
    final total = int.tryParse(_totalCtrl.text.replaceAll(',', ''));
    if (total == null || total <= 0) {
      // FR-S4：不存在 0 元或空白總額交易（acceptance S3.4）。
      setState(() => _blockedMessage = '請確認總金額');
      return;
    }
    if (_hasBlockingHighlight) {
      // FR-S5：高亮欄位未處理前不可繞過（acceptance S3.5）。
      setState(() => _blockedMessage = '請先確認高亮欄位');
      return;
    }
    final draft = _draft;
    final result = ref.read(saveTransactionProvider).execute(
          accountId: _accountId!,
          categoryId: _categoryId,
          amountMinor: total,
          occurredAt: draft.date.value ?? Clock.now(),
          merchant: draft.merchant.value,
          source: 'scan',
        );
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
      // 自動跳下一張（acceptance S3.3-5：維持連續性）。
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
    final item = widget.items[_index];
    final draft = item.draft;
    final warnColor = Theme.of(context).colorScheme.errorContainer;
    return Scaffold(
      appBar: AppBar(
        title: Text('確認清單（${widget.items.length} 張）',
            key: const Key('review-title')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('${_index + 1} / ${widget.items.length}',
              key: const Key('review-progress'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('商家：${draft.merchant.value ?? '（未辨識）'}'),
                  const SizedBox(height: 8),
                  // 總額（FR-S4：一律人工檢視——可編輯）。
                  TextField(
                    key: const Key('review-total'),
                    controller: _totalCtrl,
                    decoration: const InputDecoration(
                      labelText: '總額（元）',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() => _blockedMessage = null),
                  ),
                  const SizedBox(height: 8),
                  // 日期（低信賴時高亮＋「已確認」——FR-S5）。
                  if (draft.date.needsReview)
                    Container(
                      key: const Key('review-highlight-日期'),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _confirmedFields.contains('日期') ? null : warnColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Text('請確認日期'),
                          const Spacer(),
                          if (!_confirmedFields.contains('日期'))
                            TextButton(
                              key: const Key('review-confirm-日期'),
                              onPressed: () => setState(() => _confirmedFields.add('日期')),
                              child: const Text('已確認'),
                            ),
                        ],
                      ),
                    ),
                  TextField(
                    key: const Key('review-date'),
                    controller: _dateCtrl,
                    decoration: const InputDecoration(labelText: '日期'),
                    onChanged: (_) => _confirmedFields.add('日期'),
                  ),
                  const SizedBox(height: 8),
                  const Text('分類'),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final c in ref.watch(expenseCategoriesProvider))
                        ChoiceChip(
                          key: Key('review-cat-${c.name}'),
                          label: Text(c.name),
                          selected: _categoryId == c.id,
                          onSelected: (_) => setState(() => _categoryId = c.id),
                        ),
                    ],
                  ),
                  const Text('帳戶'),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final a in ref.watch(activeAccountsProvider))
                        ChoiceChip(
                          key: Key('review-account-${a.name}'),
                          label: Text(a.name),
                          selected: _accountId == a.id,
                          onSelected: (_) => setState(() => _accountId = a.id),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_blockedMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _blockedMessage!,
                key: const Key('review-blocked'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton(
            key: const Key('review-save'),
            onPressed: _save,
            child: const Text('確認儲存'),
          ),
        ],
      ),
    );
  }
}
