import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/import/import_service.dart';
import 'package:ledger_sync/application/maintenance/data_repair_service.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';

import '../helpers/db_fixture.dart';

const _csvBase = '''
日期/時間,類型,金額,幣別,帳戶,轉入帳戶,分類,商家,備註
2026/11/18 08:30,支出,100,TWD,現金,,餐飲,早餐店,豆漿
2026/11/01 09:00,收入,50000,TWD,銀行,,收入,薪水,
''';

/// PM 2026-11-19 回歸：
/// ①「不要重複匯入」——同檔重匯必須 0 新增（舊版以當日零點比對
///   occurred_at，交易存含時間戳 → 永遠對不上＝重複灌入）。
/// ② 重複處理：略過（預設）／覆蓋。
void main() {
  late AppDatabase db;
  late ImportService service;

  setUp(() {
    db = DbFixture.create();
    service = ImportService(db, deviceId: 'test');
  });
  tearDown(() => db.close);

  test('同檔匯入兩次：第二次 0 新增（冪等；含時間戳資料）', () {
    final r1 = service.apply(_csvBase);
    expect(r1.inserted, 2);
    final r2 = service.apply(_csvBase);
    expect(r2.inserted, 0, reason: '舊版去重用當日零點比對 → 重複灌入（PM 實測）');
    expect(r2.skippedDuplicate, 2);
    final n = db.select('SELECT COUNT(*) c FROM transactions').first['c'] as int;
    expect(n, 2, reason: '不得重複');
  });

  test('預設略過：同鍵不同商家 → 略過不覆蓋', () {
    service.apply(_csvBase);
    final changed = _csvBase.replaceFirst('早餐店', '早餐店A');
    final r = service.apply(changed);
    expect(r.inserted, 0);
    expect(r.skippedDuplicate, 2);
    expect(r.overwritten, 0);
    final m = db.select(
            "SELECT merchant FROM transactions WHERE merchant LIKE '早餐店%'")
        .first['merchant'] as String;
    expect(m, '早餐店', reason: '略過模式不得改動既有資料');
  });

  test('覆蓋模式：以匯入內容更新既有交易（商家/金額）', () {
    service.apply(_csvBase);
    // 金額在去重鍵內（日期＋金額＋備註＋帳戶）——僅改商家＝同鍵 → 覆蓋生效。
    final changed = _csvBase.replaceFirst('早餐店', '早餐店B');
    final r = service.apply(changed, overwriteDuplicates: true);
    expect(r.overwritten, 2, reason: '兩列皆命中既有（同鍵，商家不同）');
    expect(r.inserted, 0);
    final n = db.select('SELECT COUNT(*) c FROM transactions').first['c'] as int;
    expect(n, 2, reason: '覆蓋不新增列');
    final m = db.select(
            "SELECT merchant FROM transactions WHERE merchant LIKE '早餐店%'")
        .first['merchant'] as String;
    expect(m, '早餐店B');
  });

  test('資料修復：信用卡 none→pending＋孤兒交易軟刪除', () {
    // � 種子：信用卡帳戶＋none 支出；孤兒交易（帳戶已不存在）
    db.select(
        "INSERT INTO accounts (id,type,name,currency,opening_amount_minor,"
        "archived,created_at,updated_at,hlc) VALUES "
        "('c-1','credit','卡','TWD',0,0,1,1,'0.t')");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) VALUES "
        "('t-1','expense',800,'TWD','c-1',1,'manual','none',1,1,'0.t')");
    db.select(
        "INSERT INTO transactions (id,kind,amount_minor,currency,account_id,"
        "occurred_at,source,settlement_status,created_at,updated_at,hlc) VALUES "
        "('t-orphan','expense',500,'TWD','ghost',1,'manual','none',1,1,'0.t')");

    final r = DataRepairService(db, deviceId: 'test').run();
    expect(r.creditPendingFixed, 1);
    expect(r.orphansFixed, 1);
    expect(db.select(
            "SELECT settlement_status FROM transactions WHERE id='t-1'")
        .first['settlement_status'], 'pending');
    expect(db.select(
            "SELECT deleted_at FROM transactions WHERE id='t-orphan'")
        .first['deleted_at'], isNotNull, reason: '孤兒交易軟刪除（可於最近刪除還原）');
    // 冪等：重跑不再動
    final r2 = DataRepairService(db, deviceId: 'test').run();
    expect(r2.creditPendingFixed, 0);
    expect(r2.orphansFixed, 0);
  });
}
