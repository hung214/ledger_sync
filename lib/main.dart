import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'application/first_run_bootstrap.dart';
import 'application/maintenance/data_repair_service.dart';
import 'application/lock/app_lock_controller.dart';
import 'application/lock/lock_fe_state.dart';
import 'application/providers.dart';
import 'platform/file_saver/file_saver.dart';
import 'application/scan/blob_store_factory.dart';
import 'application/scan/scan_state.dart';
import 'application/sync/local_backup.dart';
import 'application/sync/sync_coordinator.dart';
import 'application/sync/sync_fe_state.dart';
import 'data/sqlite/app_database.dart';
import 'platform/auth/google_oauth.dart';
import 'platform/cloud/drive/google_drive_adapter.dart';
import 'platform/cloud/unconfigured_cloud_adapter.dart';
import 'platform/scan/image_qr_scan.dart';
import 'presentation/app_root.dart';

/// LedgerSync — 本地優先記帳 App（production 入口）。
///
/// 啟動流程：文件目錄開檔案 DB（`<documents>/ledger_sync/ledger.db`）→
/// 首次啟動播種（空帳本自動建立內建分類集＋預設現金帳戶）→ 注入 provider：
/// - `dbProvider`／`blobStoreProvider`（附件 blobs——native=檔案、web=IndexedDB）
/// - `deviceId`（per-device：首次產生並持久化於 settings `device.id`——HLC/同步用）
/// - `cloudAdapterProvider`／`oauthProvider`／`syncCoordinatorProvider`（FR-Y7）
///
/// **雲端憑證**：以 `--dart-define=GOOGLE_OAUTH_CLIENT_ID=…`（＋`…_CLIENT_SECRET`）
/// 注入；未設定 → [UnconfiguredCloudAdapter] 降級（UI 顯示未設定，不崩）——
/// 設定步驟見 `specs/plan/pm-actions.md`。M1 過渡期 DB 為明文 SQLite
/// （SQLCipher 屬 SP-1，research §3）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}${Platform.pathSeparator}ledger_sync');
  final blobsDir = Directory('${root.path}${Platform.pathSeparator}blobs');
  await blobsDir.create(recursive: true);
  final db = AppDatabase.open('${root.path}${Platform.pathSeparator}ledger.db');
  await FirstRunBootstrap.seedIfNeeded(db);

  // 裝置 id（per-device；HLC 與同步 manifest 用）——首次啟動產生並持久化。
  var deviceId = db.getSetting('device.id') ?? '';
  if (deviceId.isEmpty) {
    deviceId = 'd-${const Uuid().v7().substring(0, 8)}';
    db.setSetting('device.id', deviceId);
  }

  // 桌面每日自動本地備份（>24h；保留 7 份——安全網，不需雲端憑證）。
  unawaited(runLocalBackupIfNeeded(db, '${root.path}${Platform.pathSeparator}backups'));

  // 雲端 adapter（憑證未就緒 → 降級；不影響本地功能）。
  final cloud =
      GoogleDriveAdapter.fromEnvironment() ?? const UnconfiguredCloudAdapter();

  // 一次性資料修復（PM 2026-11-19：信用卡 pending＋孤兒交易；冪等）。
  final repair = DataRepairService(db, deviceId: deviceId).run();
  // ignore: avoid_print
  print('資料修復：信用卡 pending ${repair.creditPendingFixed} 筆、孤兒交易 ${repair.orphansFixed} 筆');

  runApp(
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        blobStoreProvider.overrideWithValue(newBlobStore(dirPath: blobsDir.path)),
        cloudAdapterProvider.overrideWithValue(cloud),
        oauthProvider.overrideWithValue(googleOAuthSignIn(cloud)),
        syncCoordinatorProvider.overrideWithValue(SyncCoordinator(db, cloud,
            deviceId: deviceId, blobs: newBlobStore(dirPath: blobsDir.path))),
        // PC／桌面掃描（PM 2026-10-29）：檔案對話框選圖 → 確認頁。
        // **模式分流**（PM 2026-11-22）：電子發票＝**只走 QR**（不用文字
        // 辨識）；紙本發票＝**OCR 抓印刷發票號碼**（無條碼——Apple Vision，
        // iOS/macOS；其他平台回退 QR→空白卡）。
        importPipelineProvider.overrideWith((ref) {
          final scanner = const ImageQrScanner();
          return () async {
            final mode = ref.read(scanModeProvider);
            return mode == ScanMode.paper
                ? scanner.pickAndScanPaper()
                : scanner.pickAndScan();
          };
        }),
        // App 鎖接線（PM 2026-11-19 修復：清空資料/設定 PIN 讀此 provider
        // 時拋 UnimplementedError → 靜默無反應）。生物辨識 M2 才接 local_auth
        // ——先恆 false（鎖屏直接走 PIN）。
        appLockControllerProvider
            .overrideWithValue(AppLockController(db, biometricEnabled: false)),
        biometricAuthProvider.overrideWithValue(() async => false),
        fileSaverProvider.overrideWithValue(const FileSaver()),
      ],
      child: AppRoot(db: db),
    ),
  );
}
