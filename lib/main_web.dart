import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:web/web.dart' as web;

import 'application/first_run_bootstrap.dart';
import 'application/scan/attachment_store.dart';
import 'application/scan/blob_store_factory.dart';
import 'data/sqlite/app_database.dart';
import 'platform/auth/google_oauth_web.dart';
import 'platform/cloud/drive/google_drive_adapter.dart';
import 'platform/cloud/drive/google_apis_drive_api.dart';

/// **Web（PWA）入口**（P3.5；PM 2026-11-16 決策 A：採用 PWA）。
///
/// 以**正式** `AppDatabase.openWeb()`（wasm＋IndexedDB VFS）跑完整流程：
/// 遷移 v1→v6 → 首次啟動播種 → 寫入真實資料（帳戶＋oplog 同交易）→
/// 讀回驗證 → 沖刷關閉。**同一瀏覽器第二次載入**應偵測到已播種旗標並讀回
/// 資料＝跨重新載入持久化（P3.6）。
///
/// 結果逐步寫入 `document.title` 並 POST 至同源 `/spike-result`
/// （供 `chrome --headless` 自動驗證；沿用 Spike SP-8 模式）。
///
/// 建置：`flutter build web --release -t lib/main_web.dart`
/// （正式 App UI 接線屬 P6/P8——本入口先驗證資料層全通。）
const String _kWebClientId = String.fromEnvironment('GOOGLE_OAUTH_WEB_CLIENT_ID');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];

  void step(String s) {
    log.add(s);
    web.document.title = 'WEB ${log.join(' | ')}';
    try {
      final req = web.RequestInit(method: 'POST', body: s.toJS);
      web.window.fetch('/spike-result'.toJS, req).toDart.ignore();
    } catch (_) {}
  }

  var ok = true;

  try {
    step('1-open-web-db');
    final db = await AppDatabase.openWeb(); // wasm＋IndexedDB＋遷移 v1→v6
    step('2-migrated-v${db.schemaVersion}');

    await FirstRunBootstrap.seedIfNeeded(db);
    final cats = db.categoriesByKind('expense').length;
    step('3-bootstrap cats=$cats');

    final seeded = db.getSetting('web.p3.seeded') ?? '';
    if (seeded.isEmpty) {
      // 首次載入：以真實 DAO 寫入（帳戶＋oplog 於同一交易——SDD §5.1 契約）。
      final now = DateTime.now().millisecondsSinceEpoch;
      db.insertAccountWithOplog(
        AccountRow(
          id: 'a-web-p3',
          type: 'cash',
          name: 'Web 驗證帳戶',
          currency: 'TWD',
          openingAmountMinor: 0,
          archived: false,
          createdAt: now,
          updatedAt: now,
          hlc: '0.web-p3',
        ),
        OplogRow(
          entity: 'accounts',
          entityId: 'a-web-p3',
          hlc: '0.web-p3',
          payload: null,
          packedSeq: 0,
        ),
      );
      db.setSetting('web.p3.seeded', '1');
      step('4-first-run-wrote');
    } else {
      step('4-reload-detected');
    }

    final accounts = db.allAccounts();
    final ours = accounts.where((a) => a.id == 'a-web-p3').length;
    db.close();
    step('5-verify accounts=${accounts.length} ours=$ours');
    if (ours != 1) ok = false;

    // ── P4：附件 BlobStore（web=IndexedDB）寫入→讀回→刪除往返 ──
    final blobs = newBlobStore(); // web 分支 → IdbBlobStore
    final jpeg = AttachmentStore.compress(_synthJpeg());
    final digest = sha256.convert(jpeg).toString();
    await blobs.write(digest, jpeg);
    final back = await blobs.read(digest);
    final same = back != null && sha256.convert(back).toString() == digest;
    step('6-blob-roundtrip ${same ? 'ok' : 'MISMATCH'} bytes=${back?.length}');
    if (!same) ok = false;

    await blobs.delete(digest);
    final gone = await blobs.read(digest);
    step('7-blob-delete ${gone == null ? 'ok' : 'STILL-THERE'}');
    if (gone != null) ok = false;

    // ── P5：雲端層 smoke（GIS 載入＋授權狀態；無 client id＝未設定非失敗）──
    if (_kWebClientId.isEmpty) {
      step('8-cloud skipped(需 GOOGLE_OAUTH_WEB_CLIENT_ID——pm-actions §1.1)');
    } else {
      try {
        await loadGoogleIdentityServices();
        final cloud = GoogleDriveAdapter(
            GoogleApisDriveApi(GisBearerClient(_kWebClientId)));
        final authed = await cloud.isConfigured();
        step('8-cloud gis-ready authorized=$authed');
      } catch (e) {
        step('8-cloud FAIL $e');
        ok = false;
      }
    }

    step(ok ? 'RESULT:OK' : 'RESULT:FAIL(see steps)');
  } catch (e) {
    step('RESULT:FAIL $e');
  }

  runApp(_WebProbeApp(log: log));
}

/// 合成 8x8 純色 JPEG（純 Dart image 套件；P4.5 往返用——不依賴檔案）。
Uint8List _synthJpeg() {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return img.encodeJpg(image, quality: 70);
}

class _WebProbeApp extends StatelessWidget {
  const _WebProbeApp({required this.log});

  final List<String> log;

  @override
  Widget build(BuildContext context) {
    final ok = log.any((l) => l.startsWith('RESULT:OK'));
    return MaterialApp(
      home: Scaffold(
        backgroundColor: ok ? const Color(0xFF0B7A75) : const Color(0xFFD64545),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(ok ? '✅ Web 資料層驗證通過' : '❌ Web 資料層驗證失敗',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                for (final line in log)
                  Text(line,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
