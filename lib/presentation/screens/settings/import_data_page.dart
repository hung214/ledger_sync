import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../application/import/import_models.dart';
import '../../../application/import/import_service.dart';
import '../../../application/sync/backup_service.dart';
import '../../../application/sync/sync_fe_state.dart';

/// 從其他 App 匯入（I4；PM 2026-11-16 決策：入口＝設定→資料管理→從其他 App 匯入）。
///
/// 流程：**選檔（CSV）→ 預覽（筆數/期間/金額合計/新帳戶分類/重複/錯誤/非 TWD）
/// → 確認（匯入前自動備份——I5）→ 報告（含「取消本批匯入」——可回溯）**。
///
/// 測試 keys：`dm-import-pick`／`dm-import-confirm`／`dm-import-undo`／
/// `dm-import-done`／`dm-import-back`。
class ImportDataPage extends ConsumerStatefulWidget {
  const ImportDataPage({super.key});

  @override
  ConsumerState<ImportDataPage> createState() => _ImportDataPageState();
}

enum _Step { pick, preview, done }

class _ImportDataPageState extends ConsumerState<ImportDataPage> {
  _Step _step = _Step.pick;
  bool _busy = false;
  ImportPreview? _preview;
  ImportReport? _report;
  bool _backedUp = false;
  bool _overwrite = false; // 重複處理：略過（預設）／覆蓋（PM 2026-11-19）
  String? _error;

  static final NumberFormat _fmt = NumberFormat('#,###');

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: 'CSV', extensions: ['csv', 'txt']),
      ]);
      if (file == null) {
        setState(() => _busy = false); // 使用者取消
        return;
      }
      final bytes = await file.readAsBytes();
      final csv = utf8.decode(bytes, allowMalformed: true);
      final preview = ref.read(_importServiceProvider).preview(csv);
      // I5：雲端連結狀態（預覽頁提示是否會先雲端備份）。
      var cloudOk = false;
      try {
        cloudOk = await ref.read(cloudAdapterProvider).isConfigured();
      } catch (_) {
        cloudOk = false;
      }
      setState(() {
        _pendingBytes = bytes;
        _preview = preview;
        _cloudConfigured = cloudOk;
        _step = _Step.preview;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '讀檔失敗：$e';
        _busy = false;
      });
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // I5：匯入前自動備份（雲端已連結時；未連結＝UI 已明示無雲端備份）。
      try {
        final cloud = ref.read(cloudAdapterProvider);
        if (_cloudConfigured == true) {
          await BackupService(ref.read(dbProvider), cloud, deviceId: _deviceId())
              .export();
          _backedUp = true;
        }
      } catch (_) {
        _backedUp = false; // 備份失敗不擋匯入（oplog 契約仍可回溯）
      }

      final report = ref.read(_importServiceProvider).apply(
          utf8.decode(_pendingBytes, allowMalformed: true),
          overwriteDuplicates: _overwrite);
      setState(() {
        _report = report;
        _step = _Step.done;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '匯入失敗：$e';
        _busy = false;
      });
    }
  }

  void _undo() {
    final n = ref.read(_importServiceProvider).undoLastBatch();
    ref.invalidate(ledgerProvider);
    ref.invalidate(activeAccountsProvider); // 匯入可能以名稱建立帳戶
    ref.refreshAllData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已取消本批匯入（軟刪除 $n 筆；其他裝置會同步刪除）')));
      Navigator.of(context).pop();
    }
  }

  String _deviceId() {
    try {
      return ref.read(syncCoordinatorProvider).deviceId;
    } catch (_) {
      return 'device-local';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('從其他 App 匯入')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : switch (_step) {
              _Step.pick => _buildPick(context),
              _Step.preview => _buildPreview(context),
              _Step.done => _buildDone(context),
            },
    );
  }

  Widget _buildPick(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('選擇 CSV 檔案',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(
                    '支援其他記帳 App 匯出的 CSV（日期／類型／金額／帳戶／分類…，'
                    '中英文表頭皆可）。未知帳戶與分類會自動建立；重複的交易可選擇略過（預設）或覆蓋。'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('dm-import-pick'),
                  onPressed: _pick,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('選擇檔案'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context) {
    final p = _preview!;
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('預覽', style: t.titleMedium),
                const SizedBox(height: 8),
                Text('可匯入 ${p.rows.length} 筆'
                    '（支出 ${p.totalsMinor[ImportKind.expense] == 0 ? 0 : _fmt.format(p.totalsMinor[ImportKind.expense]! ~/ 100)}、'
                    '收入 ${p.totalsMinor[ImportKind.income] == 0 ? 0 : _fmt.format(p.totalsMinor[ImportKind.income]! ~/ 100)}、'
                    '轉帳 ${p.rows.where((r) => r.kind == ImportKind.transfer).length} 筆）'),
                if (p.minDate != null)
                  Text('期間：${_fmtDate(p.minDate!)} ~ ${_fmtDate(p.maxDate!)}'),
                Text('重複：${p.duplicateLines.length} 筆（處理方式見下方選擇）'),
                RadioGroup<bool>(
                  groupValue: _overwrite,
                  onChanged: (v) => setState(() => _overwrite = v!),
                  child: Column(children: [
                    RadioListTile<bool>(
                      key: const Key('import-dup-skip'),
                      value: false,
                      title: const Text('略過（預設）'),
                      dense: true,
                    ),
                    RadioListTile<bool>(
                      key: const Key('import-dup-overwrite'),
                      value: true,
                      title: const Text('覆蓋既有資料（以匯入內容更新該筆）'),
                      dense: true,
                    ),
                  ]),
                ),
                Text('錯誤列（略過）：${p.errors.length} 筆'),
                if (p.skippedCurrency.isNotEmpty)
                  Text('非 TWD（略過）：${p.skippedCurrency.length} 筆',
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (p.newAccounts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('將自動建立帳戶：${p.newAccounts.join('、')}',
                      style: t.bodySmall),
                ],
                for (final e in p.newMainCategories.entries)
                  if (e.value.isNotEmpty)
                    Text(
                        '將自動建立分類（${e.key == 'expense' ? '支出' : '收入'}）：'
                        '${e.value.join('、')}',
                        style: t.bodySmall),
              ],
            ),
          ),
        ),
        if (_cloudConfigured == false)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('⚠ 未連結雲端：本次匯入不會先雲端備份（仍可「取消本批匯入」）。',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              key: const Key('dm-import-back'),
              onPressed: () => setState(() {
                _step = _Step.pick;
                _preview = null;
              }),
              child: const Text('選其他檔案'),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('dm-import-confirm'),
              onPressed: _confirm,
              child: const Text('開始匯入'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDone(BuildContext context) {
    final r = _report!;
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('匯入完成', style: t.titleMedium),
                const SizedBox(height: 8),
                Text('新增 ${r.inserted} 筆（含轉帳 ${r.transfersInserted} 筆）'),
                Text('自動跳過重複 ${r.skippedDuplicate} 筆'),
                if (r.overwritten > 0) Text('覆蓋既有 ${r.overwritten} 筆'),
                if (r.errorRows > 0) Text('錯誤略過 ${r.errorRows} 筆'),
                if (r.skippedCurrencyRows > 0)
                  Text('非 TWD 略過 ${r.skippedCurrencyRows} 筆'),
                Text('自動建立帳戶 ${r.accountsCreated} 個、分類 ${r.categoriesCreated} 個'),
                Text(_backedUp ? '已先完成雲端備份 ✓' : '（未連結雲端：本次無雲端備份）',
                    style: t.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              key: const Key('dm-import-undo'),
              onPressed: _undo,
              child: const Text('取消本批匯入'),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('dm-import-done'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ],
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}/${d.month}/${d.day}';

  // 檔案 bytes 在 pick 與 confirm 間傳遞（避免重讀檔）。
  Uint8List _pendingBytes = Uint8List(0);
  bool? _cloudConfigured;
}

/// ImportService provider（本頁專用；與資料管理頁共用 db）。
final _importServiceProvider = Provider<ImportService>(
    (ref) => ImportService(ref.watch(dbProvider), deviceId: 'import'));
