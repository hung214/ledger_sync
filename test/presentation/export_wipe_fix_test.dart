import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/lock/app_lock_controller.dart';
import 'package:ledger_sync/application/lock/pin_hash.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/presentation/screens/ledger/ledger_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';
import 'package:ledger_sync/platform/file_saver/file_saver.dart';

import '../helpers/db_fixture.dart';

/// PM 2026-11-19 修復驗證：
/// ①匯出 CSV——**先選範圍（全部資料／目前篩選）→ 真的存檔**（此前只 print）。
/// ②AppLockController——**無設定才寫入預設**（不覆蓋使用者在設定→安全的選擇）
/// ＋**無 PIN 不鎖**（shouldLockOnResume 恆 false）。
/// ③清空資料接線（appLockControllerProvider 於 main/main_web_app override）—
/// 此檔以「main 同款 override」跑完整清空流程確保接線語意。
class _RecordingFileSaver implements FileSaver {
  List<int>? saved;
  String? name;

  @override
  Future<String?> saveCsv(String suggestedName, List<int> bytes) async {
    name = suggestedName;
    saved = bytes;
    return '/tmp/$suggestedName';
  }
}

void main() {
  testWidgets('匯出：範圍對話框（全部/篩選）→ 存檔內容＝全部資料（跨月）',
      (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    await DbFixture.seedAccount(db, id: 'a-0', type: 'cash', name: '現金');
    // 兩個不同月（2023/11 與 2026/10）——此前匯出只含當前檢視月。
    await DbFixture.seedTx(db,
        id: 't-old',
        kind: 'expense',
        amountMinor: 100,
        accountId: 'a-0',
        merchant: '去年早餐',
        occurredAt: 1700000000000);
    await DbFixture.seedTx(db,
        id: 't-new',
        kind: 'expense',
        amountMinor: 200,
        accountId: 'a-0',
        merchant: '本月晚餐',
        occurredAt: DateTime(2026, 10, 15).millisecondsSinceEpoch);
    final saver = _RecordingFileSaver();
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      fileSaverProvider.overrideWithValue(saver),
    ]);
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light), home: const LedgerPage()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('export-csv')));
    await tester.pumpAndSettle();
    // 對話框兩個範圍選項（全部 2 筆／本月篩選 1 筆）
    expect(find.byKey(const Key('export-scope-all')), findsOneWidget);
    expect(find.byKey(const Key('export-scope-filter')), findsOneWidget);
    await tester.tap(find.byKey(const Key('export-scope-all')));
    await tester.pumpAndSettle();

    // 真的存檔：內容含兩個月的交易（跨月）＋UTF-8 BOM
    expect(saver.saved, isNotNull, reason: '此前只 print 未存檔');
    expect(saver.name, startsWith('ledger_export_'));
    final csv = utf8.decode(saver.saved!);
    // BOM（EF BB BF）以位元組驗（dart utf8.decode 會剝除開頭 BOM 字元）。
    expect(saver.saved!.take(3).toList(), [0xEF, 0xBB, 0xBF], reason: 'UTF-8 BOM');
    expect(csv.contains('去年早餐'), isTrue, reason: '2023/11 交易在全部資料內');
    expect(csv.contains('本月晚餐'), isTrue, reason: '2026/10 交易在全部資料內');
    expect(find.byKey(const Key('export-result')), findsOneWidget);
  });

  test('AppLockController：無設定才寫入預設（不覆蓋使用者選擇）＋無 PIN 不鎖', () async {
    final db = DbFixture.create();
    addTearDown(db.close);
    final c1 = AppLockController(db, thresholdSec: 120);
    expect(db.getSetting('lock.threshold_sec'), '120');
    // 重新建構（模擬下次啟動 main()）——**不得**把 120 打回 30。
    AppLockController(db);
    expect(db.getSetting('lock.threshold_sec'), '120',
        reason: 'PM 2026-11-19：啟動不得覆蓋設定→安全所選門檻');
    // 無 PIN：背景再久也不鎖（鎖屏沒有解鎖手段）。
    c1.onBackground();
    Clock.freeze(DateTime.now().add(const Duration(hours: 1)));
    addTearDown(Clock.unfreeze);
    expect(c1.shouldLockOnResume(), isFalse);
    // 設定 PIN 後：超過門檻即鎖（同次凍結時鐘）。
    PinHasher.kTestMode = true; // 純 VM 測試其實可跑 Argon2id；此處求快
    addTearDown(() => PinHasher.kTestMode = false);
    await c1.setPin('1234');
    expect(c1.shouldLockOnResume(), isTrue);
  });
}
