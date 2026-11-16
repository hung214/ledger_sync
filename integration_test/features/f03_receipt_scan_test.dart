import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/scan/scan_state.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/domain/entities/transaction_draft.dart';
import 'package:ledger_sync/domain/services/invoice_qr_parser.dart';
import 'package:ledger_sync/domain/services/receipt_field_extractor.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/app_shell.dart';
import 'package:ledger_sync/presentation/screens/scan/import_page.dart';
import 'package:ledger_sync/presentation/screens/scan/review_page.dart';
import 'package:ledger_sync/presentation/screens/scan/scan_page.dart';
import 'package:ledger_sync/application/scan/blob_store_factory.dart';

import '../../integration_test/helpers/hooks.dart';
import '../../test/helpers/in_memory_cloud_adapter.dart';
import '../../test/helpers/db_fixture.dart';
import '../../test/helpers/gherkin/gherkin.dart';
import '../../test/helpers/invoice_qr_fixtures.dart';

/// F03-FE 情境執行器（@FE @M4 @FR-S，6 情境：掃描入口/權限引導/確認清單
/// 逐張儲存/低信賴高亮/連拍計數/桌面匯入）。
///
/// 來源：specs/plan/tests/frontend/F03_receipt-scan.feature（rootBundle 資產）。
/// 句型登記簿：specs/plan/tests/dsl.md §3（v0.7）。
/// 掃描器/OCR 為平台層——FE 情境以解析結果注入 scanDraftsProvider（影像回放
/// 語意，dsl §3.2）；桌面快捷鍵以 pressShortcut 注入（T-H8）。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final doc = GherkinParser.parse(await rootBundle
      .loadString('integration_test/features/F03_receipt-scan.feature'));

  testWidgets('F03-FE：發票掃描 UI（6 情境）', (tester) async {
    final w = _World(tester);
    final runner = GherkinRunner();
    _bind(runner, w);
    try {
      final executed = await runner.run(
        doc,
        tagFilter: (tags) => tags.contains('@FE'),
      );
      expect(executed, 6, reason: 'F03-FE 應執行 6 個情境（5 @P0＋連拍 @P1）');
      // ignore: avoid_print
      print(runner.log.join('\n'));
    } finally {
      Clock.unfreeze();
      for (final db in w.dbs) {
        db.close();
      }
      for (final c in w.containers) {
        c.dispose();
      }
      for (final dir in w.blobDirs) {
        // ignore: avoid_catches_without_on_clauses
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });
}

class _World {
  _World(this.tester);

  final WidgetTester tester;
  final List<AppDatabase> dbs = [];
  final List<ProviderContainer> containers = [];
  final List<Directory> blobDirs = [];
  AppDatabase? db;
  ProviderContainer? container;
  bool pumped = false;

  final accounts = <String, String>{};
  final categories = <String, String>{};
}

void _bind(GherkinRunner runner, _World w) {
  // ── Background ───────────────────────────────────────────
  runner.on(r'App 已完成首次設定$', (p) async {
    final db = DbFixture.create();
    w.dbs.add(db);
    w.db = db;
    w.pumped = false;
    w.accounts.clear();
    w.categories.clear();
  });

  runner.on(r'已建立帳戶「{name}」\(餘額 {amount}\)$', (p) async {
    final id = 'a-${w.accounts.length}';
    await DbFixture.seedAccount(
      w.db!,
      id: id,
      type: 'cash',
      name: p['name']!,
      opening: _amount(p['amount']!),
    );
    w.accounts[p['name']!] = id;
  });

  runner.on(r'已建立分類{names}$', (p) async {
    final names =
        RegExp('「([^」]+)」').allMatches(p['names']!).map((m) => m.group(1)!).toList();
    for (var i = 0; i < names.length; i++) {
      final id = 'c-${w.categories.length}';
      await DbFixture.seedCategory(w.db!, id: id, kind: 'expense', name: names[i]);
      w.categories[names[i]] = id;
    }
  });

  // ── Given：掃描前置 ───────────────────────────────────────
  runner.on(r'相機權限未授權$', (p) async {
    await _ensureApp(w);
    // 預設即 notDetermined（每情境新 container）——防禦性確認。
    expect(w.container!.read(cameraPermissionProvider), CameraPermissionState.notDetermined,
        reason: 'FR-S6：未授權前置');
  });

  runner.on(r'掃描頁已掃 {n} 張標準測資發票$', (p) async {
    await _ensureApp(w);
    await _openScanPage(w); // 權限 granted（掃描頁可用）
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      _injectScan(w, _standardInvoiceItem());
    }
    await w.tester.pumpAndSettle();
  });

  runner.on(r'OCR 對日期欄位的信賴度為 {conf}（低於 {threshold} 門檻）$', (p) async {
    await _ensureApp(w);
    await _openScanPage(w);
    // T-H6 fixture 1：民國日期 → 信賴 0.5（<0.7，acceptance S3.5）。
    final ext = ReceiptFieldExtractor.extract(OcrReceiptFixtures.text(1));
    final draft = TransactionDraft(
      merchant: ext.merchant,
      totalMinor: ext.totalMinor,
      date: ext.date,
      sellerTaxId: ext.sellerTaxId.value,
    );
    _injectScan(w, ScannedItem(draft: draft, photoBytes: _smallJpeg()));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'使用者位於 Windows 版（無相機裝置）$', (p) async {
    await _ensureApp(w);
    w.container!.read(cameraAvailableProvider.notifier).set(false);
    await w.tester.pumpAndSettle();
  });

  // ── When：導航與掃描互動 ──────────────────────────────────
  runner.on(r'開啟總覽頁$', (p) async {
    await _ensureApp(w);
    await _gotoTab(w, '總覽');
  });

  runner.on(r'開啟明細頁$', (p) async {
    await _ensureApp(w);
    await _gotoTab(w, '明細');
  });

  runner.on(r'開啟總覽頁並按下「掃描」$', (p) async {
    await _ensureApp(w);
    await _gotoTab(w, '總覽');
    await _tapScanEntry(w);
  });

  runner.on(r'拒絕權限$', (p) async {
    await w.tester.tap(find.byKey(const Key('perm-deny')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'掃描標準測資發票（左QR\+右QR）$', (p) async {
    await _ensureApp(w);
    await _openScanPage(w);
    _injectScan(w, _standardInvoiceItem());
    await w.tester.pumpAndSettle();
  });

  runner.on(r'再掃描 {n} 張$', (p) async {
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      _injectScan(w, _standardInvoiceItem());
    }
    await w.tester.pumpAndSettle();
  });

  runner.on(r'進入確認卡$', (p) async {
    await w.tester.tap(find.byKey(const Key('scan-finish')));
    await w.tester.pumpAndSettle();
    expect(w.tester.any(find.byType(ReviewPage)), isTrue, reason: '應進入確認清單');
  });

  runner.on(r'確認第 {n} 張（分類={cat}、帳戶={a}）並按下「確認儲存」$', (p) async {
    // 分類/帳戶 ChoiceChip 選擇（預填「其他」/首個未封存帳戶→改選）。
    await w.tester.tap(find.byKey(Key('review-cat-${p['cat']!}')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(Key('review-account-${p['a']!}')));
    await w.tester.pumpAndSettle();
    await w.tester.tap(find.byKey(const Key('review-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「{label}」而未處理$', (p) async {
    // 直接按儲存（跳過高亮欄位之「已確認」）——FR-S5 擋下路徑。
    await w.tester.tap(find.byKey(const Key('review-save')));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下「{label}」$', (p) async {
    await w.tester.tap(find.text(p['label']!));
    await w.tester.pumpAndSettle();
  });

  runner.on(r'按下 Ctrl\+Shift\+S$', (p) async {
    await pressShortcut(w.tester,
        {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.keyS});
  });

  runner.on(r'從相簿匯入 fixture {n}$', (p) async {
    await w.tester.tap(find.byKey(const Key('import-pick')));
    await w.tester.pumpAndSettle();
  });

  // ── Then：斷言（specific 顯示變體先於 generic 顯示「{text}」——註冊順序教訓）
  runner.on(r'明細頁即時顯示該 1 筆（帶 📷 附件標記）$', (p) async {
    // 推入路由時主殼 offstage——先返回主殼（harness 教訓）。
    final navigator = w.tester.state<NavigatorState>(find.byType(Navigator).first);
    while (navigator.canPop()) {
      await navigator.maybePop();
      await w.tester.pumpAndSettle();
    }
    await _gotoTab(w, '明細');
    expect(w.tester.any(find.text('📷')), isTrue, reason: '掃描交易應帶附件標記');
  });

  runner.on(r'顯示「掃描」按鈕（獨立於快記大鈕）$', (p) async {
    expect(w.tester.any(find.byKey(const Key('scan-entry'))), isTrue,
        reason: 'FR-S6：掃描入口獨立於快記大鈕');
  });

  runner.on(r'顯示「前往設定開啟權限」且不離開 App$', (p) async {
    expect(w.tester.any(find.text('前往設定開啟權限')), isTrue, reason: 'FR-S6 拒絕後引導');
    expect(w.tester.any(find.byType(ScanPage)), isTrue, reason: '不離開 App（掃描頁仍在）');
  });

  runner.on(r'顯示「已掃 {n} 張」$', (p) async {
    expect(w.tester.any(find.text('已掃 ${p['n']!} 張')), isTrue, reason: 'FR-S7 連拍計數');
  });

  runner.on(r'顯示 {n} 個縮圖$', (p) async {
    final n = int.parse(p['n']!);
    for (var i = 0; i < n; i++) {
      expect(w.tester.any(find.byKey(Key('scan-thumbnail-$i'))), isTrue,
          reason: '縮圖 $i 應存在');
    }
  });

  runner.on(r'顯示「{n} / {total}」$', (p) async {
    expect(w.tester.any(find.text('${p['n']!} / ${p['total']!}')), isTrue,
        reason: '確認清單逐張進度');
  });

  runner.on(r'顯示「請確認日期」（高亮樣式）$', (p) async {
    expect(w.tester.any(find.byKey(const Key('review-highlight-日期'))), isTrue,
        reason: 'FR-S5：低信賴欄位高亮');
  });

  runner.on(r'顯示「請先確認高亮欄位」且不建立交易$', (p) async {
    expect(w.tester.any(find.text('請先確認高亮欄位')), isTrue, reason: 'FR-S5 擋下提示');
    final live = w.db!.allTransactions().where((t) => t.deletedAt == null).length;
    expect(live, 0, reason: '未處理高亮不得入帳');
  });

  runner.on(r'導向「相簿/檔案匯入」$', (p) async {
    expect(w.tester.any(find.byType(ImportPage)), isTrue, reason: 'FR-S6：無相機導向匯入');
  });

  runner.on(r'顯示「{text}」$', (p) async {
    expect(w.tester.any(find.text(p['text']!, skipOffstage: false)), isTrue,
        reason: '應顯示「${p['text']}」');
  });
}

// ── 輔助 ─────────────────────────────────────────────

Future<void> _ensureApp(_World w) async {
  if (w.pumped) return;
  final blobsDir = await Directory.systemTemp.createTemp('ledger_blobs_fe');
  w.blobDirs.add(blobsDir);
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(w.db!),
    blobStoreProvider.overrideWithValue(newBlobStore(dirPath: blobsDir.path)),
    // 啟動同步鉤子（FR-Y11 afterSave——F07-BE 接線）防 UnimplementedError。
    syncCoordinatorProvider.overrideWithValue(
        SyncCoordinator(w.db!, InMemoryCloudAdapter(), deviceId: 'd-A')),
    // 匯入管線回放（T-H6 fixture 1 OCR——FR-S6 桌面路徑；平台檔案選擇屬生產接線）。
    importPipelineProvider.overrideWithValue(() async {
      final ext = ReceiptFieldExtractor.extract(OcrReceiptFixtures.text(1));
      return ScannedItem(
        draft: TransactionDraft(
          merchant: ext.merchant,
          totalMinor: ext.totalMinor,
          date: ext.date,
          sellerTaxId: ext.sellerTaxId.value,
        ),
        photoBytes: _smallJpeg(),
      );
    }),
  ]);
  w.containers.add(container);
  w.container = container;
  // 情境預設相機可用（行動語意；S6「無相機裝置」Given 顯式設 false——
  // macOS 測試行程 Platform 判定為桌面，須覆寫才能驗掃描頁/權限流）。
  container.read(cameraAvailableProvider.notifier).set(true);
  await w.tester.pumpWidget(
    KeyedSubtree(
      key: ValueKey('app-shell-${w.dbs.length}'),
      child: UncontrolledProviderScope(container: container, child: const AppShell()),
    ),
  );
  await w.tester.pumpAndSettle();
  w.pumped = true;
}

Future<void> _gotoTab(_World w, String tab) async {
  await w.tester.tap(find.byKey(Key('nav-$tab')));
  await w.tester.pumpAndSettle();
}

/// 掃描入口：相機可用 → ScanPage；無相機 → ImportPage（FR-S6 路由語意）。
Future<void> _tapScanEntry(_World w) async {
  await w.tester.tap(find.byKey(const Key('scan-entry')).first);
  await w.tester.pumpAndSettle();
}

/// 權限 granted 並開啟掃描頁（情境資料步驟；不經權限 UI）。
Future<void> _openScanPage(_World w) async {
  w.container!.read(cameraPermissionProvider.notifier).allow();
  await _gotoTab(w, '總覽');
  await _tapScanEntry(w);
  expect(w.tester.any(find.byType(ScanPage)), isTrue, reason: '掃描頁應已開啟');
}

/// 影像回放注入（掃描器回呼契約＝scanDraftsProvider.add）。
void _injectScan(_World w, ScannedItem item) {
  w.container!.read(scanDraftsProvider.notifier).add(item);
}

/// T-H6 標準發票（左 77 碼＋右明細）→ 掃描結果＋小圖。
ScannedItem _standardInvoiceItem() => ScannedItem(
      draft: InvoiceQrParser.parse(InvoiceQrFixtures.leftQr77, InvoiceQrFixtures.rightQr)!,
      photoBytes: _smallJpeg(),
    );

/// 100x80 小圖（附件來源 fixture；最長邊 ≤1600 不縮、重編 JPEG q70）。
Uint8List _smallJpeg() {
  final photo = img.Image(width: 100, height: 80);
  return img.encodeJpg(photo, quality: 90);
}

int _amount(String s) {
  final m = RegExp(r'^-?[\d,]+').firstMatch(s.trim());
  if (m == null) throw FormatException('金額格式未支援：$s');
  return int.parse(m.group(0)!.replaceAll(',', ''));
}
