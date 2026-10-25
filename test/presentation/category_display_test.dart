import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/data/sqlite/app_database.dart';
import 'package:ledger_sync/presentation/category_display.dart';

/// 分類顯示規則（PM 2026-10-25：修正「快記圖示與類別設定不同」）。
///
/// 契約：①自身 icon 在圖示庫→用；②子類別 icon 為**空字串**（非 null）→ 取
/// **主類別**圖示；③皆無（含舊代碼 `shopping_basket`）→ 🏷️。
void main() {
  CategoryRow cat(String id,
          {String? parentId, String name = 'x', String? icon}) =>
      CategoryRow(
        id: id,
        kind: 'expense',
        parentId: parentId,
        name: name,
        isSystem: false,
        icon: icon,
        createdAt: 0,
        updatedAt: 0,
        hlc: '0.test',
      );

  test('主類別：圖示在庫 → 原樣；非庫內代碼（舊 shopping_basket）→ 🏷️', () {
    final food = cat('c-food', name: '餐飲食品', icon: '🍜');
    expect(categoryEmojiOf(food), '🍜');
    expect(categoryEmojiOf(cat('c-x', name: '舊', icon: 'shopping_basket')),
        defaultCategoryEmoji);
    expect(categoryEmojiOf(cat('c-y', name: '無')), defaultCategoryEmoji);
  });

  test('子類別：icon 為空字串 → 取**主類別**圖示（不可用 `??` 判斷）', () {
    final byId = categoryIndex([
      cat('c-food', name: '餐飲食品', icon: '🍜'),
      cat('c-food-s0', parentId: 'c-food', name: '早餐', icon: ''),
    ]);
    final sub = byId['c-food-s0']!;
    expect(sub.icon, '', reason: '前置：子類別入庫為空字串');
    expect(categoryEmojiOf(sub, byId: byId), '🍜',
        reason: '圖示跟隨主類別（修正前：空字串使 ?? 不回退 → 無圖示）');
    expect(categoryLabelOf(sub, byId: byId), '🍜 早餐');
  });

  test('子類別：主類別亦無有效圖示 → 🏷️；未提供索引 → 🏷️', () {
    final byId = categoryIndex([
      cat('c-a', name: '甲', icon: 'shopping_basket'),
      cat('c-a-s0', parentId: 'c-a', name: '子', icon: ''),
    ]);
    expect(categoryEmojiOf(byId['c-a-s0']!, byId: byId), defaultCategoryEmoji);
    expect(categoryEmojiOf(byId['c-a-s0']!), defaultCategoryEmoji,
        reason: '無 byId 時不做主類別回退');
  });
}
