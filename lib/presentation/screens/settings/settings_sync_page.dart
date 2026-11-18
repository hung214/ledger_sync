import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../application/providers.dart';
import '../../../application/sync/sync_fe_state.dart';
import 'sync_conflicts_page.dart';

/// 雲端與同步設定頁（FR-Y7/Y11；SDD §8 IA「設定同步」——07-prototype）：
/// 連結授權（帳號授權式——**無同步密碼**）／立即同步（同步中…→已同步 N 筆）
/// ／待同步計數／上次同步時間／衝突檢視入口／從雲端還原（新裝置）。
class SettingsSyncPage extends ConsumerStatefulWidget {
  const SettingsSyncPage({super.key});

  @override
  ConsumerState<SettingsSyncPage> createState() => _SettingsSyncPageState();
}

class _SettingsSyncPageState extends ConsumerState<SettingsSyncPage> {
  bool _linking = false; // 連結 OAuth 流程中（等待「同意授權」）
  bool _restoring = false; // 還原 OAuth 流程中（S7.4 #1：導向 Google 登入）
  bool _linkSuccess = false; // 授權完成（連結成功＋兩步驟驗證建議）
  bool _syncing = false;
  String? _syncResult; // 「已同步 N 筆變更」
  String? _restoreResult; // 「還原完成」/「此帳號沒有可還原的資料」
  String? _error;
  late String _syncMode; // F16/U4：per-transaction／batch／manual
  late bool _wifiOnly; // F16/U5：附件僅 Wi-Fi 同步

  @override
  void initState() {
    super.initState();
    final db = ref.read(dbProvider);
    _syncMode = db.getSetting('sync.mode') ?? 'batch';
    _wifiOnly = db.getSetting('backup.attachments_wifi_only') == 'true';
  }

  void _setSyncMode(String mode) {
    setState(() => _syncMode = mode);
    ref.read(dbProvider).setSetting('sync.mode', mode);
  }

  void _setWifiOnly(bool v) {
    setState(() => _wifiOnly = v);
    ref.read(dbProvider).setSetting('backup.attachments_wifi_only', v ? 'true' : 'false');
  }

  bool get _linked => (ref.watch(syncAccountProvider) ?? '').isNotEmpty;

  /// 連結第一步（FR-Y7）：進入登入畫面（等待「同意授權」——兩步互動）。
  void _beginLink() => setState(() {
        _linking = true;
        _error = null;
      });

  /// 連結第二步（授權）：OAuth seam → 帳號落 settings → 連結成功。
  /// （「同步密碼」UI 一律不存在——帳號授權式，SDD §7.1。）
  Future<void> _approve() async {
    final email = await ref.read(oauthProvider)();
    if (!mounted) return;
    if (email == null) {
      // 未設定（憑證未就緒）或使用者取消——給明確回饋（避免靜默無反應）。
      var configured = true;
      try {
        configured = await ref.read(cloudAdapterProvider).isConfigured();
      } catch (_) {
        configured = false;
      }
      if (!mounted) return;
      setState(() {
        _linking = false;
        _error = configured ? '未完成授權（已取消）' : '雲端功能尚未設定（Google 憑證未就緒）';
      });
      return;
    }
    ref.read(syncAccountProvider.notifier).link(email);
    setState(() {
      _linking = false;
      _linkSuccess = true;
      _syncResult = null;
    });
  }

  /// 從雲端還原第一步（FR-Y2/AC-08；驗收 S7.4 #1）：導向 Google 登入
  /// （兩步互動——與連結流程一致；還原前須先登入同帳號）。
  void _beginRestore() => setState(() {
        _restoring = true;
        _restoreResult = null;
        _error = null;
      });

  /// 從雲端還原第二步（S7.4 #2）：登入 → bootstrap → 結果回饋。
  Future<void> _approveRestore() async {
    final email = await ref.read(oauthProvider)();
    if (!mounted) return;
    if (email == null) {
      setState(() => _restoring = false); // 取消
      return;
    }
    setState(() {
      _restoring = false;
      _syncing = true;
      _restoreResult = null;
    });
    ref.read(syncAccountProvider.notifier).link(email);
    await ref.read(syncCoordinatorProvider).bootstrap();
    if (!mounted) return;
    final hasData = ref.read(dbProvider).allAccounts().isNotEmpty;
    setState(() {
      _syncing = false;
      _restoreResult = hasData ? '還原完成' : '此帳號沒有可還原的資料';
    });
  }

  /// 立即同步（FR-Y11）：同步中… → 已同步 N 筆變更。
  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncResult = null;
      _error = null;
    });
    final pendingBefore = ref.read(pendingOpsProvider);
    await ref.read(syncCoordinatorProvider).sync();
    afterSyncRefresh(container!);
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncResult = '已同步 $pendingBefore 筆變更';
    });
  }

  ProviderContainer? get container =>
      ProviderScope.containerOf(context, listen: false);

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(syncAccountProvider);
    final pending = ref.watch(pendingOpsProvider);
    final lastSync = ref.watch(lastSyncAtProvider);
    final conflicts = ref.watch(syncEventsProvider);
    // 憑證未就緒（UnconfiguredCloudAdapter）——開頁即說明（不用點了才知道）。
    final configured = ref.watch(cloudConfiguredProvider).valueOrNull ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text('雲端備份與同步')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (!configured) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_outlined,
                        color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '雲端功能尚未設定——Google 憑證未就緒。'
                        '本地記帳不受影響；憑證就緒後可於此連結雲端同步與備份。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_restoring) ...[
            // 還原登入步（驗收 S7.4 #1→#2）：無論是否已連結，選「從雲端
            // 還原」後一律導向 Google 登入（FR-Y2 兩步互動）。
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            const Center(
                child: Text('Google 登入', key: Key('google-signin'))),
            Center(
              child: FilledButton(
                key: const Key('oauth-approve'),
                onPressed: _approveRestore,
                child: const Text('同意授權'),
              ),
            ),
          ] else if (!_linked) ...[
            // 未連結（FR-Y7 授權式；無同步密碼 UI）。
            if (_linking) ...[
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 12),
              const Center(
                  child: Text('Google 登入', key: Key('google-signin'))),
              Center(
                child: FilledButton(
                  key: const Key('oauth-approve'),
                  onPressed: _approve,
                  child: const Text('同意授權'),
                ),
              ),
            ] else
              Center(
                child: FilledButton.icon(
                  key: const Key('sync-link'),
                  // 憑證未就緒：停用（說明卡已解釋原因——避免死路）。
                  onPressed: configured ? _beginLink : null,
                  icon: const Icon(Icons.link),
                  label: const Text('登入 Google 並啟用雲端備份'),
                ),
              ),
          ] else ...[
            // 已連結：帳號＋同步操作。
            if (_linkSuccess) ...[
              Text('連結成功',
                  key: const Key('link-success'),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.primary)),
              const Text('建議為此帳號開啟兩步驟驗證'),
              const SizedBox(height: 8),
            ],
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_done_outlined),
                title: Text(account!),
                subtitle: lastSync == null
                    ? null
                    : Text('上次同步 今天 ${DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(lastSync))}',
                        key: const Key('last-sync')),
              ),
            ),
            const SizedBox(height: 8),
            if (_syncing)
              const Center(child: Text('同步中…'))
            else
              FilledButton.icon(
                key: const Key('sync-now'),
                onPressed: _syncNow,
                icon: const Icon(Icons.sync),
                label: const Text('立即同步'),
              ),
            if (_syncResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_syncResult!, key: const Key('sync-result')),
              ),
            const SizedBox(height: 8),
            Text('待同步 $pending 筆', key: const Key('pending-count')),
            Card(
              child: ListTile(
                key: const Key('sync-conflicts-entry'),
                leading: Icon(
                  conflicts.isEmpty
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_outlined,
                  color: conflicts.isEmpty ? null : Theme.of(context).colorScheme.error,
                ),
                title: Text('${conflicts.length} 筆衝突'),
                subtitle: const Text('被覆蓋內容可檢視（後寫入者勝）'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const SyncConflictsPage()),
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('restore-cloud'),
              onPressed: _syncing ? null : _beginRestore,
              icon: const Icon(Icons.restore),
              label: const Text('從雲端還原'),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同步模式（三選一）',
                      style: Theme.of(context).textTheme.titleMedium),
                  RadioGroup<String>(
                    groupValue: _syncMode,
                    onChanged: (v) => _setSyncMode(v!),
                    child: Column(children: [
                      RadioListTile<String>(
                        key: const Key('sync-mode-per'),
                        value: 'per-transaction',
                        title: const Text('每筆自動同步（記一筆傳一筆）'),
                      ),
                      RadioListTile<String>(
                        key: const Key('sync-mode-batch'),
                        value: 'batch',
                        title: const Text('節能批次（預設：記帳後 30 秒＋閒置 15 分）'),
                      ),
                      RadioListTile<String>(
                        key: const Key('sync-mode-manual'),
                        value: 'manual',
                        title: const Text('僅手動（啟動同步＋按鈕）'),
                      ),
                    ]),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.rocket_launch_outlined),
                    title: const Text('啟動同步（必做）'),
                    subtitle: const Text('開啟 App／回前台時自動執行一次'),
                    trailing: Text('固定開啟',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700)),
                  ),
                  SwitchListTile(
                    key: const Key('sync-attachments-wifi'),
                    value: _wifiOnly,
                    onChanged: _setWifiOnly,
                    title: const Text('附件僅 Wi-Fi 同步'),
                  ),
                ],
              ),
            ),
          ),
          if (_restoreResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_restoreResult!, key: const Key('restore-result')),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
