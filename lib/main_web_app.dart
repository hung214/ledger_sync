import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import 'application/first_run_bootstrap.dart';
import 'application/providers.dart';
import 'application/scan/blob_store_factory.dart';
import 'application/scan/scan_state.dart';
import 'application/sync/sync_coordinator.dart';
import 'application/sync/sync_fe_state.dart';
import 'data/sqlite/app_database.dart';
import 'platform/auth/google_oauth.dart';
import 'platform/auth/google_oauth_web.dart';
import 'platform/cloud/drive/google_apis_drive_api.dart';
import 'platform/cloud/drive/google_drive_adapter.dart';
import 'platform/cloud/unconfigured_cloud_adapter.dart';
import 'platform/scan/image_qr_scan.dart';
import 'presentation/app_shell.dart';

/// **Web（PWA）正式入口**（P6/P8；PM 2026-11-16 決策 A：採用 PWA）。
///
/// 與 `lib/main.dart`（native）同一組 provider 注入約定，差異：
/// - DB：`AppDatabase.openWeb()`（wasm＋IndexedDB；遷移 v1→v6 同一套）
/// - 附件：`newBlobStore()`（IndexedDB；native=檔案系統）
/// - 雲端：`--dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID` 就緒 → GIS bearer；
///   否則 [UnconfiguredCloudAdapter] 降級（UI 顯示未設定，不崩）
/// - 掃描：`file_selector`＋zxing2 於 Web 可用（同桌面路徑）
///
/// 啟動里程碑 POST 至同源 `/spike-result`（自動化驗證；
/// `flutter build web --release -t lib/main_web_app.dart`）。
const String _kWebClientId = String.fromEnvironment('GOOGLE_OAUTH_WEB_CLIENT_ID');
const String _kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

void _report(String s) {
  try {
    final req = web.RequestInit(method: 'POST', body: s.toJS);
    web.window.fetch('/spike-result'.toJS, req).toDart.ignore();
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _report('web:open-db');
    final db = await AppDatabase.openWeb();
    _report('web:migrated-v${db.schemaVersion}');
    await FirstRunBootstrap.seedIfNeeded(db);

    var deviceId = db.getSetting('device.id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = 'd-${const Uuid().v7().substring(0, 8)}';
      db.setSetting('device.id', deviceId);
    }

    final cloud = _kWebClientId.isEmpty
        ? const UnconfiguredCloudAdapter()
        : GoogleDriveAdapter(GoogleApisDriveApi(GisBearerClient(_kWebClientId)));
    _report('web:providers-ready');

    runApp(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          blobStoreProvider.overrideWithValue(newBlobStore()),
          cloudAdapterProvider.overrideWithValue(cloud),
          oauthProvider.overrideWithValue(googleOAuthSignIn(cloud)),
          syncCoordinatorProvider.overrideWithValue(SyncCoordinator(db, cloud,
              deviceId: deviceId, blobs: newBlobStore())),
          importPipelineProvider
              .overrideWithValue(const ImageQrScanner().pickAndScan),
        ],
        child: const AppShell(),
      ),
    );
    _report('web:app-started v=$_kAppVersion');
  } catch (e) {
    _report('web:FAIL $e');
    runApp(_WebBootError(message: '$e'));
  }
}

class _WebBootError extends StatelessWidget {
  const _WebBootError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFFD64545),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('啟動失敗：$message',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ),
      ),
    );
  }
}
