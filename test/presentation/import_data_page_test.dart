import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_fe_state.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/screens/settings/data_management_page.dart';
import 'package:ledger_sync/presentation/screens/settings/import_data_page.dart';
import 'package:ledger_sync/presentation/theme/app_theme.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// I4/I5 匯入入口 UI 測試：資料管理入口 → 選檔（fake file_selector）→
/// 預覽 → 匯入 → 報告 → **取消本批匯入**（軟刪除；I5 可回溯）。
void main() {
  const csv = '日期,類型,金額,幣別,帳戶,轉入帳戶,分類,子分類,商家,備註\n'
      '2026/1/5,支出,195,TWD,現金,,餐食,早餐,早餐店,你好\n'
      '2026/1/6,收入,5000,TWD,現金,,薪水,,,獎金\n';

  testWidgets('資料管理頁有「從其他 App 匯入」入口', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const DataManagementPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-entry')), findsOneWidget);
  });

  testWidgets('預覽 → 匯入 → 報告 → 取消本批（軟刪除可回溯）', (tester) async {
    final db = DbFixture.create();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      cloudAdapterProvider.overrideWithValue(InMemoryCloudAdapter()),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    FileSelectorPlatform.instance =
        _FakeFileSelector(XFile.fromData(Uint8List.fromList(utf8.encode(csv)),
            name: 'andro.csv'));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const ImportDataPageHost()),
    ));
    await tester.pumpAndSettle();

    // 選檔 → 預覽
    await tester.tap(find.byKey(const Key('dm-import-pick')));
    await tester.pumpAndSettle();
    expect(find.textContaining('可匯入 2 筆'), findsOneWidget);
    expect(find.textContaining('將自動建立帳戶'), findsOneWidget);

    // 匯入 → 報告
    await tester.tap(find.byKey(const Key('dm-import-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('新增 2 筆'), findsOneWidget);
    final txCount = db
        .select('SELECT COUNT(*) c FROM transactions WHERE deleted_at IS NULL')
        .first['c'] as int;
    expect(txCount, 2);

    // 取消本批 → 軟刪除＋墓標 oplog（同步安全）
    await tester.tap(find.byKey(const Key('dm-import-undo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final active = db
        .select(
            'SELECT COUNT(*) c FROM transactions WHERE deleted_at IS NULL')
        .first['c'] as int;
    expect(active, 0, reason: '取消本批後全部軟刪除（可回溯）');
    final tombstones = db
        .select("SELECT COUNT(*) c FROM oplog WHERE entity='transactions' "
            "AND payload IS NULL")
        .first['c'] as int;
    expect(tombstones, 2, reason: '墓標 oplog（NULL payload）→ 其他裝置同步刪除');
  });
}

/// 匯入頁 host（直接推頁——入口已有專屬測試）。
class ImportDataPageHost extends StatelessWidget {
  const ImportDataPageHost({super.key});

  @override
  Widget build(BuildContext context) => const ImportDataPage();
}

class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector(this.file);

  final XFile? file;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      file;
}
