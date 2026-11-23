
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import 'package:file_selector/file_selector.dart';

import '../../../core/file_saver.dart';
import '../../../platform/web_file_picker.dart';

import '../../../application/sync/backup_service.dart';
import '../../../platform/cloud/cloud_storage_adapter.dart';
import '../../../platform/cloud/unconfigured_cloud_adapter.dart';
import '../../../application/wipe/wipe_service.dart';
import 'import_data_page.dart';
import '../../../application/scan/blob_store.dart';
import '../../../application/scan/scan_state.dart';
import '../../../application/sync/sync_fe_state.dart';
import '../../../application/lock/lock_fe_state.dart';
import '../../theme/app_theme.dart';

/// 資料管理頁（FR-O3；驗收 S9.1/S9.2）：清空資料三重防護——
/// ①警告（未連雲端「無雲端可還原」＋可先匯出備份檔入口）②PIN ③確認文字；
/// 已連雲端加驗身分（重新登入雲端帳號——錯誤帳號拒絕，S9.2 #2）。
///
/// 清空執行交 [WipeService]（BE F09 已驗：本地全表＋附件＋含雲端 LedgerSync/
/// 全刪；不復活閘由 SyncCoordinator 偵測——其他裝置同步顯示「雲端資料已不存在」）。
/// 設定入口接線屬 F07-FE 回頭項（M5 暫停——_openSettings 同批恢復）。
///
/// 測試 keys：wipe-start / wipe-backup-entry / wipe-warning-continue /
/// wipe-pin-input / wipe-pin-submit / wipe-confirm-input / wipe-confirm-submit /
/// wipe-oauth-button / wipe-done-home。
class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key});

  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementPageState();
}

enum _WipeStep { idle, scope, warning, pin, oauth, done }

class _DataManagementPageState extends ConsumerState<DataManagementPage> {
  _WipeStep _step = _WipeStep.idle;
  bool _busy = false;
  String? _dmMessage;

  /// 備份到檔案（I5+/本機備份；不需要雲端——macOS=存檔對話框、web=下載）。
  Future<void> _backupToFile() async {
    setState(() {
      _busy = true;
      _dmMessage = null;
    });
    try {
      final db = ref.read(dbProvider);
      final svc =
          BackupService(db, _cloudOrUnconfigured(), deviceId: _deviceIdOf());
      final bytes = Uint8List.fromList(await svc.encode(svc.snapshot()));
      final now = DateTime.now();
      final name = 'ledger_backup_'
          '${now.year.toString().padLeft(4, '0')}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}'
          '_${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}.db';
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) {
        setState(() => _busy = false); // 取消
        return;
      }
      // web：getSaveLocation 回 dummy ''——改傳**建議檔名**（file_saver_web
      // 以它作瀏覽器下載檔名）；native：完整路徑照舊。
      await saveBytesToPath(location.path == '' ? name : location.path, bytes);
      setState(() {
        _dmMessage = '已備份：${location.path == '' ? name : location.path}';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _dmMessage = '備份失敗：$e';
        _busy = false;
      });
    }
  }

  /// 從檔案還原（**二次確認**——會覆蓋目前全部資料；單一 DB transaction 冪等）。
  Future<void> _restoreFromFile() async {
    try {
      // web（PWA）：`<input type="file">`——iOS Safari 的 File System
      // Access API 僅支援 image/video，.db/.json 選不了（PM 2026-11-23）；
      // native 維持 file_selector 官方對話框。
      final file = kIsWeb
          ? await pickWebFile(accept: '.db,.json,application/octet-stream')
          : await openFile(acceptedTypeGroups: [
              const XTypeGroup(label: '備份檔', extensions: ['db', 'json']),
            ]);
      if (file == null) return; // 取消
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('從檔案還原'),
          content: const Text('還原會以備份檔**覆蓋目前全部資料**（交易／帳戶／分類／預算／設定），'
              '且無法復原。確定要還原嗎？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                key: const Key('dm-restore-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('確定還原')),
          ],
        ),
      );
      if (ok != true) return;
      setState(() {
        _busy = true;
        _dmMessage = null;
      });
      final bytes = await readBytesFromPath(file.path);
      final db = ref.read(dbProvider);
      await BackupService(db, _cloudOrUnconfigured(), deviceId: _deviceIdOf())
          .restoreFromBytes(db, bytes);
      if (!mounted) return;
      // 還原後衍生快取全部失效。
      ref.invalidate(ledgerProvider);
      ref.invalidate(activeAccountsProvider);
      ref.refreshAllData();
      ref.invalidate(recentDeletionsProvider);
      ref.invalidate(expenseCategoriesProvider);
      ref.invalidate(incomeCategoriesProvider);
      ref.invalidate(activeAccountsProvider);
      setState(() {
        _dmMessage = '已從檔案還原 ✓';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dmMessage = '還原失敗：$e';
        _busy = false;
      });
    }
  }

  CloudStorageAdapter _cloudOrUnconfigured() {
    try {
      return ref.read(cloudAdapterProvider);
    } catch (_) {
      return const UnconfiguredCloudAdapter();
    }
  }

  String _deviceIdOf() {
    try {
      return ref.read(syncCoordinatorProvider).deviceId;
    } catch (_) {
      return 'device-local';
    }
  }

  bool _pinError = false;
  bool _oauthError = false;

  final _pinController = TextEditingController();

  /// 勾選之刪除範圍（PM 2026-10-24；預設全選）。
  final Set<WipeScope> _scopes = {
    WipeScope.transactions,
    WipeScope.categories,
    WipeScope.accounts,
    WipeScope.budgets,
  };

  /// 「回到系統預設值」（與局部範圍互斥）：全清空＋重新播種內建集。
  bool _factoryReset = false;

  bool get _linked =>
      (ref.read(dbProvider).getSetting('sync.account') ?? '').isNotEmpty;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  /// 執行清空（WipeService——BE F09 三情境已驗契約）。
  Future<void> _executeWipe() async {
    setState(() => _busy = true);
    try {
      final db = ref.read(dbProvider);
      final linked = _linked;
      BlobStore? blobs;
      try {
        blobs = ref.read(blobStoreProvider);
      } catch (_) {
        blobs = null; // 生產未接線（main() override 前）防護——測試必注入
      }
      final service = WipeService(db,
          cloud: linked ? ref.read(cloudAdapterProvider) : null,
          blobs: blobs);
      if (_factoryReset) {
        // 回到系統預設值：全清空（含雲端資料夾）＋下次啟動重新播種內建集。
        await service.wipe(includeCloud: linked);
      } else {
        // 局部刪除（PM 2026-10-24）：刪除＋oplog 墓標（同步安全）。
        String deviceId = 'device-local';
        try {
          deviceId = ref.read(syncCoordinatorProvider).deviceId;
        } catch (_) {
          // 未接線（測試未注入）→ 預設裝置 id。
        }
        service.wipeScoped(_scopes, deviceId: deviceId);
      }
      // 範圍刪除可能軟刪交易/分類/帳戶/預算 → 衍生快取一律失效重算
      // （PM 2026-10-25：明細範圍刪除後「最近刪除」須看得到）。
      ref.invalidate(ledgerProvider);
      ref.invalidate(activeAccountsProvider);
      ref.refreshAllData();
      ref.invalidate(recentDeletionsProvider);
      ref.invalidate(expenseCategoriesProvider);
      ref.invalidate(incomeCategoriesProvider);
      ref.invalidate(activeAccountsProvider);
      if (mounted) {
        setState(() {
          _step = _WipeStep.done;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清空失敗：$e')));
      }
    }
  }

  /// 加驗身分（S9.2）：重新登入雲端帳號——帳號不符拒絕執行。
  Future<void> _verifyOauth() async {
    setState(() => _busy = true);
    final email = await ref.read(oauthProvider)();
    if (!mounted) return;
    final linked = ref.read(dbProvider).getSetting('sync.account') ?? '';
    if (email == null || (linked.isNotEmpty && email != linked)) {
      setState(() {
        _oauthError = true;
        _busy = false;
      });
      return;
    }
    await _executeWipe();
  }

  /// 防呆入口（驗收 S9.2 邊界：清空前提示可先匯出備份檔）。
  /// 雲端備份接線屬 F07-FE（main() 尚未注入 cloud/sync provider——try 防護）。
  Future<void> _exportBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_linked) {
      messenger.showSnackBar(const SnackBar(
          content: Text('未連結雲端——連結後可備份至雲端（設定→雲端同步）')));
      return;
    }
    try {
      final db = ref.read(dbProvider);
      final cloud = ref.read(cloudAdapterProvider);
      final deviceId = ref.read(syncCoordinatorProvider).deviceId;
      final path = await BackupService(db, cloud, deviceId: deviceId).export();
      messenger.showSnackBar(SnackBar(content: Text('備份已匯出：$path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('匯出失敗：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('資料管理')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : switch (_step) {
              _WipeStep.idle => _buildIdle(context),
              _WipeStep.scope => _buildScope(context),
              _WipeStep.warning => _buildWarning(context),
              _WipeStep.pin => _buildPin(context),
              _WipeStep.oauth => _buildOauth(context),
              _WipeStep.done => _buildDone(context),
            },
    );
  }

  Widget _buildIdle(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('備份與還原',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('把全部資料（交易／帳戶／分類／預算…）備份成一個檔案，'
                    '或從備份檔還原（**會覆蓋目前資料**）。換機／分享給朋友也靠這個。'
                    '已連結雲端者另有自動雲端備份（見「雲端備份」）。'),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.tonal(
                    key: const Key('dm-backup-file'),
                    onPressed: _busy ? null : _backupToFile,
                    child: const Text('備份到檔案'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    key: const Key('dm-restore-file'),
                    onPressed: _busy ? null : _restoreFromFile,
                    child: const Text('從檔案還原'),
                  ),
                ]),
                if (_dmMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_dmMessage!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('從其他 App 匯入',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('把其他記帳 App 匯出的 CSV 帶進本帳本'
                    '（先預覽、匯入前自動備份、可取消本批）。'),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const Key('import-entry'),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const ImportDataPage()));
                    if (mounted) {
                      // 匯入／取消後衍生快取一律失效（PM 2026-10-25 慣例）。
                      ref.invalidate(ledgerProvider);
      ref.invalidate(activeAccountsProvider);
      ref.refreshAllData();
                      ref.invalidate(expenseCategoriesProvider);
                      ref.invalidate(incomeCategoriesProvider);
                      ref.invalidate(activeAccountsProvider);
                    }
                  },
                  child: const Text('選擇 CSV 檔案'),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('清空資料', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('可勾選要刪除的範圍（明細／預設以外類別／帳戶／預算），'
                    '或「回到系統預設值」。此操作無法復原。'),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const Key('wipe-start'),
                  onPressed: () => setState(() => _step = _WipeStep.scope),
                  child: const Text('清空資料'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 刪除範圍選擇（PM 2026-10-24）：勾選要清除的範圍；「回到系統預設值」互斥。
  Widget _buildScope(BuildContext context) {
    const all = WipeScope.values;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('選擇刪除範圍',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              CheckboxListTile(
                key: const Key('wipe-scope-全部'),
                value: !_factoryReset && _scopes.length == all.length,
                title: const Text('全部（明細＋預設以外類別＋帳戶＋預算）'),
                onChanged: (v) => setState(() {
                  _factoryReset = false;
                  if (v == true) {
                    _scopes.addAll(all);
                  } else {
                    _scopes.clear();
                  }
                }),
              ),
              for (final sc in WipeScope.values)
                CheckboxListTile(
                  key: Key('wipe-scope-${sc.label}'),
                  value: _scopes.contains(sc),
                  title: Text(sc.label),
                  onChanged: _factoryReset
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _scopes.add(sc);
                            } else {
                              _scopes.remove(sc);
                            }
                          }),
                ),
              const Divider(height: 1),
              CheckboxListTile(
                key: const Key('wipe-scope-factory'),
                value: _factoryReset,
                title: const Text('回到系統預設值（清空全部並還原內建分類／現金帳戶）'),
                onChanged: (v) => setState(() {
                  _factoryReset = v == true;
                  _scopes
                    ..clear()
                    ..addAll(all);
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _step = _WipeStep.idle),
              child: const Text('取消'),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('wipe-scope-next'),
              onPressed: (!_factoryReset && _scopes.isEmpty)
                  ? null
                  : () => setState(() => _step = _WipeStep.warning),
              child: const Text('下一步'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWarning(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 40),
          const SizedBox(height: 12),
          Text(
            _linked
                ? '將刪除所有資料（含雲端 LedgerSync/ 同步與備份）'
                : '將刪除所有資料且無雲端可還原',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 6),
          // 勾選之範圍（PM 2026-10-24）。
          Text(
            _factoryReset
                ? '• 回到系統預設值（全清空＋還原內建分類／現金帳戶）'
                : '• ${_scopes.map((e) => e.label).join('、')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('wipe-backup-entry'),
            onPressed: _exportBackup,
            child: const Text('可先匯出備份檔'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('wipe-warning-continue'),
            // 未設定 PIN → 跳過 PIN 步驟（PM 2026-10-23 修復：null 比對恆
            // false 會把沒設過 PIN 的使用者鎖死在 PIN 關卡）。
            onPressed: () {
              // PM 2026-11-23：移除「輸入確認文字」步驟——PIN（有設）後直接執行。
              if (ref.read(appLockControllerProvider).hasPin) {
                setState(() => _step = _WipeStep.pin);
              } else {
                _executeWipe(); // 無 PIN → 直接清空
              }
            },
            child: const Text('下一步'),
          ),
        ],
      ),
    );
  }

  Widget _buildPin(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('輸入 PIN 以繼續'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wipe-pin-input'),
            controller: _pinController,
            obscureText: true,
            keyboardType: TextInputType.number,
          ),
          if (_pinError)
            Text('PIN 不正確',
                style: TextStyle(color: AppTokens.of(context).danger)),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('wipe-pin-submit'),
            onPressed: () async {
              final ok = await ref
                  .read(appLockControllerProvider)
                  .verifyPin(_pinController.text);
              if (!mounted) return;
              setState(() => _pinError = !ok);
              if (ok) {
                final needOauth = _factoryReset && _linked;
                if (needOauth) {
                  setState(() => _step = _WipeStep.oauth);
                } else {
                  await _executeWipe(); // PIN 後直接執行（無確認文字）
                }
              }
            },
            child: const Text('驗證'),
          ),
        ],
      ),
    );
  }

  Widget _buildOauth(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('重新登入雲端帳號',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('清空將連雲端 LedgerSync/ 一併刪除——須重新驗證身分。'),
          if (_oauthError)
            Text('帳號不符，已取消',
                style: TextStyle(color: AppTokens.of(context).danger)),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('wipe-oauth-button'),
            onPressed: _verifyOauth,
            child: const Text('以雲端帳號驗證'),
          ),
        ],
      ),
    );
  }

  Widget _buildDone(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline, size: 48),
          const SizedBox(height: 12),
          const Text('已清空', style: TextStyle(fontSize: 20)),
          const SizedBox(height: 8),
          const Text('資料已全部清除。\n下次啟動將回到首次設定（新建/還原/匯入）。'),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('wipe-done-home'),
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: const Text('回到總覽'),
          ),
        ],
      ),
    );
  }
}
