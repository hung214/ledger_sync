import '../data/sqlite/app_database.dart';

/// 分類顯示規則（**唯一來源**；PM 2026-10-25）。
///
/// 起因：各頁各自判斷圖示（`icon ?? 主類別.icon`），但**子類別的 icon 入庫為
/// 空字串 `''`（非 null）** → `??` 不觸發回退 → 快記分類欄／明細列圖示空白；
/// 且「類別設定」對非圖示庫代碼（如舊值 `shopping_basket`）顯示 🏷️，其他頁卻
/// 直接印原始字串 → **同一分類在不同頁顯示不一致**。

/// 分類圖示庫（34 個 emoji；PM 2026-10-23：`icon` 欄直接存 emoji 字元）。
const List<String> categoryEmojis = [
  '🍜', '🍚', '🍣', '🍞', '☕', '🍔', '🛒', '👗',
  '👜', '💄', '🏠', '🛏️', '🧹', '🚇', '🚌', '🚗',
  '✈️', '🎓', '📚', '✏️', '🎬', '🎮', '🏀', '📱',
  '💻', '🎧', '💊', '🏥', '🎁', '🧧', '💰', '📈',
  '🍰', '🐱',
];

/// 未設定／非圖示庫代碼之預設 emoji（與「類別設定」一致）。
const String defaultCategoryEmoji = '🏷️';

bool _known(String? icon) => icon != null && categoryEmojis.contains(icon);

/// 分類顯示 emoji（**單一規則**）：
/// ①自身 `icon` 在圖示庫內 → 用它
/// ②否則為子類別 → 取**主類別** `icon`（在庫內才用；子類別圖示跟隨主類別）
/// ③皆無 → [defaultCategoryEmoji]（🏷️）
///
/// `byId`＝分類索引（含主類別），供子類別回查主類別；未提供時不做②回退。
/// 註：`c` 為 null（未分類）之呈現由呼叫端決定（例：明細 🧾、轉帳 🔀）。
String categoryEmojiOf(CategoryRow c, {Map<String, CategoryRow>? byId}) {
  if (_known(c.icon)) return c.icon!;
  final parent = c.parentId == null ? null : byId?[c.parentId];
  if (parent != null && _known(parent.icon)) return parent.icon!;
  return defaultCategoryEmoji;
}

/// 分類顯示標籤：`emoji 名稱`（子類別＝**主類別 emoji ＋ 子類別名**）。
String categoryLabelOf(CategoryRow c, {Map<String, CategoryRow>? byId}) =>
    '${categoryEmojiOf(c, byId: byId)} ${c.name}';

/// 分類索引（供 [categoryEmojiOf]／[categoryLabelOf] 之 `byId`）。
Map<String, CategoryRow> categoryIndex(Iterable<CategoryRow> categories) =>
    {for (final c in categories) c.id: c};
