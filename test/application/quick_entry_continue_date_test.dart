import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/core/clock.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/screens/quick_entry/quick_entry_controller.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// T73（PM 2026-11-24）：**「繼續」維持最後設定日期**——補記場景
/// （改過日期後連續記帳同日期）；僅重新進入快記＝當日（autoDispose
/// 重建即 preset.time＝Clock.now()）。
ProviderContainer _container(AppDatabase db) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // afterSave 鉤子（FR-Y11）——防 syncCoordinatorProvider UnimplementedError。
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-t')),
    ]);

void main() {
  test('繼續記下一筆 → 日期維持最後設定值（昨天 18:30），金額/備註清空', () {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-1', kind: 'expense', name: '餐飲');

    final container = _container(db);
    addTearDown(container.dispose);
    final sub = container.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(sub.close);
    final ctrl = container.read(quickEntryControllerProvider.notifier);

    final yesterday = DateTime(2026, 11, 23, 18, 30);
    ctrl.selectAccountById('a-1');
    ctrl.selectCategoryById('c-1');
    ctrl.setAmount('120');
    ctrl.setOccurredAt(yesterday);
    ctrl.save(); // phase → savedDialog
    ctrl.continueEntry();

    final state = container.read(quickEntryControllerProvider);
    expect(state.occurredAt, yesterday,
        reason: 'T73——繼續不重設時間，補記連續記帳同日期');
    expect(state.amount, '', reason: '金額照舊清空');
  });

  test('重新進入快記（provider 重建）→ 日期＝當日（preset.time）', () {
    Clock.freeze(DateTime(2026, 11, 24, 12));
    final db = DbFixture.create();
    addTearDown(() {
      Clock.unfreeze();
      db.close();
    });
    DbFixture.seedAccount(db, id: 'a-1', type: 'cash', name: '現金');
    DbFixture.seedCategory(db, id: 'c-1', kind: 'expense', name: '餐飲');

    // 第一輪：改日期為昨天 → 離開（container 銷毀）。
    final c1 = _container(db);
    c1.listen(quickEntryControllerProvider, (_, _) {}); // 保活（autoDispose）。
    c1.read(quickEntryControllerProvider.notifier).selectAccountById('a-1');
    c1.read(quickEntryControllerProvider.notifier).selectCategoryById('c-1');
    c1.read(quickEntryControllerProvider.notifier).setAmount('50');
    c1.read(quickEntryControllerProvider.notifier)
        .setOccurredAt(DateTime(2026, 11, 23, 9));
    c1.dispose(); // 離開快記頁＝autoDispose 銷毀

    // 第二輪：首頁「＋」重新進入 → 新 container → 日期＝當日。
    final c2 = _container(db);
    addTearDown(c2.dispose);
    final s2 = c2.listen(quickEntryControllerProvider, (_, _) {});
    addTearDown(s2.close);
    final state = c2.read(quickEntryControllerProvider);
    expect(state.occurredAt, DateTime(2026, 11, 24, 12),
        reason: '重新進入＝當日（Clock.now()）');
  });
}
