import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

import 'data/sqlite/schema.dart';

/// **PWA 可行性 Spike 入口**（PM 2026-11-16 決策；非正式入口，僅驗證技術）。
///
/// 驗證：`sqlite3.wasm` 載入 → **我們的 `SchemaV1` 在 wasm 建立** → 寫入 →
/// 關閉重開（IndexedDB **持久化**）→ 結果寫入畫面與 `document.title`
/// （供 `chrome --headless --dump-dom` 自動讀取）。
///
/// 建置：`flutter build web -t lib/main_web_spike.dart`
/// 執行：`chrome --headless --virtual-time-budget=20000 --dump-dom <url>`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];

  void step(String s) {
    log.add(s);
    web.document.title = 'SPIKE ${log.join(' | ')}';
    // 逐步回報給同源伺服器（供 headless 自動驗證讀取；失敗不影響流程）。
    try {
      final req = web.RequestInit(method: 'POST', body: s.toJS);
      web.window.fetch('/spike-result'.toJS, req).toDart.ignore();
    } catch (_) {}
  }

  try {
    step('1-load-wasm');
    final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
    step('2-wasm-ok');

    final fs = await IndexedDbFileSystem.open(dbName: 'ledger_sync_spike');
    sqlite3.registerVirtualFileSystem(fs, makeDefault: true);
    step('3-vfs-ok');

    var db = sqlite3.open('ledger.db');
    final hasSchema = db
        .select("SELECT name FROM sqlite_master WHERE type='table' AND name='accounts'")
        .isNotEmpty;
    if (!hasSchema) {
      for (final stmt in SchemaV1.statements) {
        db.execute(stmt);
      }
      step('4-schema-created');
    } else {
      step('4-schema-existed');
    }

    db.execute(
        "INSERT INTO transactions (id, kind, amount_minor, currency, account_id, "
        "occurred_at, source, settlement_status, created_at, updated_at, hlc) "
        "VALUES ('spike-1', 'expense', 195, 'TWD', 'a-spike', "
        "${DateTime.now().millisecondsSinceEpoch}, 'manual', 'none', 0, 0, '0.spike')");
    db.dispose();
    step('5-wrote-row');

    // 重開（同 IndexedDB）→ 資料應還在（持久化）
    db = sqlite3.open('ledger.db');
    final rows = db.select('SELECT COUNT(*) AS c FROM transactions').first['c'];
    final tables = db
        .select("SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table'")
        .first['c'];
    db.dispose();
    fs.close();
    step('6-reopened rows=$rows tables=$tables');
    step('RESULT:OK');
  } catch (e) {
    step('RESULT:FAIL $e');
  }

  runApp(_SpikeApp(log: log));
}

class _SpikeApp extends StatelessWidget {
  const _SpikeApp({required this.log});
  final List<String> log;

  @override
  Widget build(BuildContext context) {
    final ok = log.last.startsWith('RESULT:OK');
    return MaterialApp(
      home: Scaffold(
        backgroundColor: ok ? const Color(0xFF0B7A75) : const Color(0xFFD64545),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(ok ? '✅ PWA Spike 通過' : '❌ PWA Spike 失敗',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                for (final line in log)
                  Text(line,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
