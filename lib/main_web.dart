import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'application/first_run_bootstrap.dart';
import 'data/sqlite/app_database.dart';

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
    step('RESULT:OK');
  } catch (e) {
    step('RESULT:FAIL $e');
  }

  runApp(_WebProbeApp(log: log));
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
