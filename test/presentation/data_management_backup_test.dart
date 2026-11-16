import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/presentation/screens/settings/data_management_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';

/// I5+ 本機檔案備份/還原（資料管理「備份與還原」卡——不需要雲端憑證）：
/// 備份→檔案存在且可解析；還原→資料覆蓋（單一 DB transaction 冪等）＋二次確認。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ledger_backup_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('備份到檔案 → 檔案產生（含交易資料）→ 從檔案還原 → 資料回來', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    // 造一筆交易（快記管線太深——直接 SQL seed 於 fixture 完成後補一列）
    db.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES ('a-1','cash','現金','TWD',0,0,1,1,'0.t')");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) "
        "VALUES ('t-1','expense',5000,'TWD','a-1',1760000000000,'manual','none',1,1,'0.t')");
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final savePath = '${tmp.path}/backup.db';
    FileSelectorPlatform.instance = _FakeSaveAndPick(savePath: savePath);
    final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const DataManagementPage()),
    ));
    await tester.pumpAndSettle();

    // 備份到檔案（真實檔案 I/O 須於 runAsync 內等待——widget 測試假時鐘不推進 IO）
    await tester.tap(find.byKey(const Key('dm-backup-file')));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)));
    // ignore: avoid_print
    print('DBG-TEST file=${File(savePath).existsSync() ? File(savePath).lengthSync() : -1}');
    // ignore: avoid_print
    print('DBG-MSG 已備份=${find.textContaining('已備份').evaluate().length} 備份失敗=${find.textContaining('備份失敗').evaluate().length} busy=${find.byType(CircularProgressIndicator).evaluate().length}');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(File(savePath).existsSync(), isTrue, reason: '備份檔應產生');
    final bytes = File(savePath).readAsBytesSync();
    expect(bytes.length, greaterThan(10));
    expect(utf8.decode(bytes.sublist(1)), contains('transactions'),
        reason: '明文快照（flag=0）應含 transactions 表');

    // 清空 DB（模擬換機）→ 從檔案還原 → 資料回來
    db.execute('DELETE FROM transactions');
    expect(db.select('SELECT COUNT(*) c FROM transactions').first['c'], 0);

    await tester.tap(find.byKey(const Key('dm-restore-file')));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('dm-restore-confirm')));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        db.select('SELECT COUNT(*) c FROM transactions').first['c'], 1,
        reason: '還原後交易回來');
    expect(find.textContaining('已從檔案還原'), findsOneWidget);
  });
}

/// getSaveLocation→指定路徑；openFile→該檔（同一 fake 串起備份↔還原）。
class _FakeSaveAndPick extends FileSelectorPlatform {
  _FakeSaveAndPick({required this.savePath});

  final String savePath;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async =>
      FileSaveLocation(savePath);

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      XFile(savePath);
}
