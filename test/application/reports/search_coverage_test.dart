import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/reports/search_service.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

import '../../helpers/db_fixture.dart';

/// **搜尋範圍驗證**（T36，PM 2026-11-23「最上面的搜尋沒有效果」）：
/// 實測 22 筆中 19 筆無商家/備註——只搜 merchant/note 等於沒效果。
/// 擴大範圍＝**分類名稱／帳戶名稱／金額（元）**＋既有商家/備註。
void main() {
  late AppDatabase db;
  late SearchService svc;

  setUp(() async {
    db = DbFixture.create();
    await DbFixture.seedStandardScenario(db);
    svc = SearchService(db);
  });

  tearDown(() => db.close());

  test('分類名稱（餐飲）→ 命中該分類的交易', () {
    final rows = svc.search(keyword: '餐飲');
    expect(rows.map((r) => r.id), contains('t-1'), reason: 't-1＝c-food 餐飲');
  });

  test('帳戶名稱（銀行）→ 命中該帳戶的交易', () {
    final rows = svc.search(keyword: '銀行');
    expect(rows.map((r) => r.id), contains('t-2'), reason: 't-2＝bank 銀行');
  });

  test('金額（元）→ 命中該金額的交易（整數與小數）', () {
    expect(svc.search(keyword: '300').map((r) => r.id), contains('t-2'),
        reason: 't-2＝300 元（30000 minor）');
    expect(svc.search(keyword: '1.2').map((r) => r.id), contains('t-1'),
        reason: 't-1＝1.2 元（120 minor）——小數也支援');
  });

  test('商家/備註（既有路徑）不回歸', () {
    // seedStandardScenario 的交易無商家——以 FTS/LIKE 路徑仍須可用：
    expect(svc.search(keyword: '不存在關鍵字xyz'), isEmpty);
  });
}
