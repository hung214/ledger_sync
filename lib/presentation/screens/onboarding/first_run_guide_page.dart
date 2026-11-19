import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import '../../../application/sync/backup_service.dart';
import '../../../application/sync/sync_fe_state.dart';
import '../../../core/file_saver.dart';
import '../../../platform/cloud/cloud_storage_adapter.dart';
import '../../../platform/cloud/unconfigured_cloud_adapter.dart';
import '../settings/import_data_page.dart';

/// 首次啟動引導（F13；tasks §6.0b——PWA 朋友入場＋兌現 F09「下次啟動回到首次設定」）。
///
/// 三條路：**全新開始**（內建分類＋現金帳戶已播種）／**從備份檔還原**／
/// **從其他 App 匯入（CSV）**。任一路徑完成 → `app.onboarded=1` → 主殼。
///
/// 測試 keys：`guide-start-fresh`／`guide-restore`／`guide-import`。
class FirstRunGuidePage extends ConsumerStatefulWidget {
  const FirstRunGuidePage({super.key, required this.onDone});

  /// 引導完成（含「略過」）——回呼主殼切換。
  final VoidCallback onDone;

  @override
  ConsumerState<FirstRunGuidePage> createState() => _FirstRunGuidePageState();
}

class _FirstRunGuidePageState extends ConsumerState<FirstRunGuidePage> {
  bool _busy = false;
  String? _error;

  Future<void> _startFresh() async => widget.onDone();

  Future<void> _restore() async {
    try {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(label: '備份檔', extensions: ['db', 'json']),
      ]);
      if (file == null) return; // 取消
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('從備份檔還原'),
          content: const Text('將以備份檔內容做為您的帳本（覆蓋目前空白帳本）。繼續嗎？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                key: const Key('guide-restore-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('確定還原')),
          ],
        ),
      );
      if (ok != true) return;
      setState(() => _busy = true);
      final db = ref.read(dbProvider);
      final bytes = await readBytesFromPath(file.path);
      await BackupService(db, _cloud(), deviceId: _deviceId())
          .restoreFromBytes(db, bytes);
      if (!mounted) return;
      ref.invalidate(ledgerProvider);
      ref.refreshAllData();
      ref.invalidate(expenseCategoriesProvider);
      ref.invalidate(incomeCategoriesProvider);
      ref.invalidate(activeAccountsProvider);
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '還原失敗：$e';
      });
    }
  }

  Future<void> _importCsv() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const ImportDataPage()));
    if (!mounted) return;
    ref.invalidate(ledgerProvider);
    widget.onDone(); // 匯入完成（或取消）皆視為完成引導——主殼內仍可再匯入
  }

  CloudStorageAdapter _cloud() {
    try {
      return ref.read(cloudAdapterProvider);
    } catch (_) {
      return const UnconfiguredCloudAdapter();
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
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 24),
                  Text('歡迎使用 LedgerSync', style: t.headlineMedium),
                  const SizedBox(height: 8),
                  Text('資料存在您自己的裝置。選擇開始方式：', style: t.bodyMedium),
                  const SizedBox(height: 20),
                  _OptionCard(
                    key: const Key('guide-start-fresh'),
                    icon: Icons.edit_note,
                    title: '全新開始',
                    subtitle: '使用內建分類（16 主類別＋子分類）與現金帳戶，馬上記第一筆',
                    onTap: _startFresh,
                  ),
                  _OptionCard(
                    key: const Key('guide-restore'),
                    icon: Icons.restore,
                    title: '從備份檔還原',
                    subtitle: '之前用 LedgerSync 備份過？選備份檔（.db）帶回全部資料',
                    onTap: _restore,
                  ),
                  _OptionCard(
                    key: const Key('guide-import'),
                    icon: Icons.upload_file,
                    title: '從其他 App 匯入（CSV）',
                    subtitle: '把 AndroMoney 等其他 App 的 CSV 帶進來（自動建立帳戶/分類）',
                    onTap: _importCsv,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _startFresh,
                    child: const Text('略過，直接開始'),
                  ),
                  const SizedBox(height: 8),
                  Text('提示：資料安全請養成備份習慣（設定→資料管理→備份到檔案）。',
                      style: t.bodySmall),
                ],
              ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
