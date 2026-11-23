import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/categories/category_service.dart';
import '../../../application/providers.dart';
import '../../../application/scan/scan_defaults.dart';
import '../../merchant_picker_dialog.dart';
import '../../../application/scan/scan_state.dart';
import '../../../core/clock.dart';
import '../../category_display.dart';
import '../quick_entry/amount_keypad.dart';
import '../quick_entry/category_picker_dialog.dart';
import '../quick_entry/quick_date_time_picker.dart';

/// 確認清單（FR-S4/S5）——**與快速記帳同款互動**（PM 2026-11-22）：
/// 置中大金額＋常駐計算機（OK＝確認儲存）、帳戶｜分類同一列（Sticky 帳戶）、
/// ◀▶ 日期快調＋DateTime picker、商家/備註欄、逐張自動前進。
///
/// 帳戶/類別預設（PM 2026-11-22）：**最後一次掃描發票入帳的帳戶與類別**
/// → 無則帳戶＝第一個現金帳戶、類別＝「其他」（入帳即記住，跨回合生效）。
/// 商家欄＝選擇器（最近商家＋直接輸入——T8）。
/// 日期＝**掃到即用**，不做確認閘（PM 2026-11-22：移除「已確認」按鈕——
/// 使用者自行以 ◀▶／picker 調整）；發票號碼自動寫入**備註欄**。
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

  String? _blockedMessage;

  // 文字欄位聚焦 → **隱藏計算機鍵盤**（PM 2026-11-23：避免遮擋畫面；
  // 系統鍵盤接手；失焦後計算機回來）。
  final _merchantFocus = FocusNode();
  final _noteFocus = FocusNode();
  bool _textEditing = false;

  void _onTextFocusChanged() {
    final editing = _merchantFocus.hasFocus || _noteFocus.hasFocus;
    if (editing != _textEditing && mounted) {
      setState(() => _textEditing = editing);
    }
  }

  @override
  void initState() {
    super.initState();
    _merchantFocus.addListener(_onTextFocusChanged);
    _noteFocus.addListener(_onTextFocusChanged);
    _loadCard(0);
  }

  @override
  void dispose() {
    _merchantFocus.removeListener(_onTextFocusChanged);
    _noteFocus.removeListener(_onTextFocusChanged);
    _merchantFocus.dispose();
    _noteFocus.dispose();
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
    // PM 2026-11-23：掃描草稿（QR/OCR）**沒有時間資訊**（時間＝00:00）——
    // 時間預設＝**當下時刻**（例：現在 12:35 → 任何日期都配 12:35），
    // 不出現深夜 00:00 的異常觀感；picker 時分沿用 initial（只改日期），
    // 使用者改時段的需求由 picker 後續版本支援。
    if (_date.hour == 0 && _date.minute == 0) {
      final now = Clock.now();
      _date = DateTime(
          _date.year, _date.month, _date.day, now.hour, now.minute);
    }
    _merchantCtrl.text = draft.merchant.value ?? '';
    // 發票號碼寫入備註欄（PM 2026-11-22：掃描帶金額/時間，發票號入備註）。
    _noteCtrl.text = draft.invoiceNo == null ? '' : '發票號 ${draft.invoiceNo}';
    // 類別預設（PM 2026-11-22：與帳戶同款 Sticky）＝**最後一次掃描入帳的
    // 類別**；無（或已刪除）→「其他」（acceptance S3.3）。
    final cats = ref.read(expenseCategoriesProvider);
    final lastCat = ref.read(dbProvider).getSetting(kScanLastCategoryKey);
    _categoryId = (lastCat != null && cats.any((c) => c.id == lastCat))
        ? lastCat
        : (cats.where((c) => c.name == '其他').map((c) => c.id).firstOrNull ??
            (cats.isEmpty ? null : cats.first.id));
    if (_accountId == null) {
      final last = ref.read(dbProvider).getSetting(kScanLastAccountKey);
      _accountId = resolveScanDefaultAccount(
          [
            for (final r in ref.read(activeAccountsProvider)) accountEntity(r)
          ],
          last);
    }
    _blockedMessage = null;
  }

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
    // 記住本次帳戶/類別＝下次掃描預設（PM 2026-11-22 Sticky 同款）。
    ref.read(dbProvider).setSetting(kScanLastAccountKey, _accountId!);
    if (_categoryId != null) {
      ref.read(dbProvider).setSetting(kScanLastCategoryKey, _categoryId!);
    }
    // 存檔即從暫存移除**該張**（縮圖單張編輯不清其他待掃——PM 2026-11-22）。
    ref.read(scanDraftsProvider.notifier).removeItem(widget.items[_index]);
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
    // 全數完成（暫存已逐張移除）：返回（acceptance S3.7：回明細頁）。
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
                  // **照片預覽＋OCR 辨識區域框**（T21，PM：辨識的文字要有框
                  // ——讓使用者看到辨識到哪段）。BoxFit.fill＝正規化框直接
                  // 映射（縮放失真可接受——指示用）。
                  if (widget.items[_index].photoBytes != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 4),
                      child: LayoutBuilder(builder: (context, box) {
                        final w = box.maxWidth;
                        final h = w * 0.75;
                        final ocrBox = widget.items[_index].ocrBox;
                        return SizedBox(
                          width: w,
                          height: h,
                          child: Stack(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                  widget.items[_index].photoBytes!,
                                  width: w,
                                  height: h,
                                  fit: BoxFit.fill,
                                  errorBuilder: (context, error,
                                          stackTrace) =>
                                      const SizedBox.shrink()),
                            ),
                            if (ocrBox != null)
                              Positioned(
                                left: ocrBox.left * w,
                                top: ocrBox.top * h,
                                width: ocrBox.width * w,
                                height: ocrBox.height * h,
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: Colors.greenAccent,
                                        width: 2.5),
                                  ),
                                ),
                              ),
                          ]),
                        );
                      }),
                    ),
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
                          onPressed: () => setState(
                              () => _date = _date.subtract(const Duration(days: 1))),
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
                                onSelected: (dt) =>
                                    setState(() => _date = dt),
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
                          onPressed: () => setState(
                              () => _date = _date.add(const Duration(days: 1))),
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
                    focusNode: _merchantFocus,
                    decoration: InputDecoration(
                        labelText: '商家（點 › 選常用商家）',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: IconButton(
                          tooltip: '選擇常用商家',
                          icon: const Icon(Icons.arrow_drop_down),
                          onPressed: _pickMerchant,
                        )),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('review-note'),
                    controller: _noteCtrl,
                    focusNode: _noteFocus,
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
<<<<<<< HEAD
            // 浮動底部計算機（快記同款）：OK＝確認儲存，鍵盤貼底常駐；
            // **文字欄位聚焦時隱藏**（PM 2026-11-23：避免遮擋輸入框——
            // 換「完成」列，點擊收起系統鍵盤並讓計算機回來）。
=======
            // 文字欄位聚焦時隱藏計算機（PM 2026-11-23）→「完成」列。
>>>>>>> pwa-accumulate
            if (_textEditing)
              Container(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12),
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
                child: Row(children: [
                  const Text('輸入文字中…',
                      style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  TextButton(
                    key: const Key('text-edit-done'),
                    onPressed: () => FocusScope.of(context).unfocus(),
                    child: const Text('完成'),
                  ),
                ]),
              )
            else
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

  /// 商家選擇器（T8：最近商家＋直接輸入新商家——可選可增）。
  Future<void> _pickMerchant() async {
    final name = await showMerchantPicker(context, ref,
        initial: _merchantCtrl.text);
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _merchantCtrl.text = name);
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
      setState(() => _categoryId = row.id);
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
