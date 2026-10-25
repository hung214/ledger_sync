import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/categories/category_service.dart';
import '../../../application/providers.dart';
import '../../../data/sqlite/app_database.dart';
import '../../category_display.dart';
import '../../theme/app_theme.dart';

/// 分類管理頁（SPEC FR-B1；設計基準 `specs/plan/ui/09-category-settings.html`
/// ＋畫廊 `category_settings_demo_page.dart`）：
/// 支出/收入分頁 → 列表（拖曳排序、子分類展開、圖示/顏色）→
/// 新增／編輯／封存／刪除（有交易引用→拒絕提示）。
///
/// 測試 keys（dsl §4.5）：cat-add／cat-name／cat-icon／cat-color／
/// cat-row-{name}／cat-sub-{parent}／cat-sub-row-{name}。
class CategorySettingsPage extends ConsumerStatefulWidget {
  const CategorySettingsPage({super.key});

  @override
  ConsumerState<CategorySettingsPage> createState() =>
      _CategorySettingsPageState();
}

class _CategorySettingsPageState extends ConsumerState<CategorySettingsPage> {
  String _kind = 'expense'; // 支出 | income
  String? _message;
  final Set<String> _expanded = {}; // 主類別展開狀態（預設收合＝09 雛型摘要列）
  late final CategoryService _service = CategoryService(ref.read(dbProvider));

  bool _isOpen(String id) => _expanded.contains(id); // 預設收合（09 雛型）

  /// 變更後刷新：本頁 setState＋**全域快取失效**（PM 2026-10-23 回報：
  /// 分類/子分類改名或改圖示後，快記/預算/明細頁不會連動——provider 快取）。
  void _refresh() {
    ref.invalidate(expenseCategoriesProvider);
    ref.invalidate(incomeCategoriesProvider);
    ref.invalidate(ledgerProvider); // 交易列的分類名稱/圖示重新解析
    setState(() {});
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    setState(() => _message = msg);
  }

  void _openForm({String? parentId, String? editId}) {
    final db = ref.read(dbProvider);
    final existing = editId == null
        ? null
        : db.categoriesByKind(_kind).firstWhere((c) => c.id == editId);
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    // 子類別**不擁有圖示**（PM 2026-10-24：圖示跟隨主類別）——表單不提供圖示選項，
    // 儲存一律清為空（''＝無圖示；顯示端取主類別圖示）。
    final isSub = parentId != null;
    var icon = isSub ? '' : (existing?.icon ?? 'shopping_basket');
    var color = existing?.color ?? 'teal';
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(sheetCtx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editId == null
                      ? (parentId == null ? '新增分類' : '新增子分類')
                      : (parentId == null ? '編輯分類' : '編輯子分類'),
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('cat-name'),
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '分類名稱',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (isSub)
                  // 子類別無圖示（PM 2026-10-24）：圖示一律跟隨主類別。
                  Text('圖示跟隨主類別（子類別不另設圖示）',
                      style: Theme.of(sheetCtx).textTheme.labelSmall)
                else ...[
                  Text(
                    '圖示（34 個 emoji）',
                    style: Theme.of(sheetCtx).textTheme.labelMedium,
                  ),
                  // PM 2026-10-23：emoji 圖示（對齊 DEMO）——icon 欄存 emoji 字元。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final e in categoryEmojis)
                            ChoiceChip(
                              key: Key('cat-icon-$e'),
                              label:
                                  Text(e, style: const TextStyle(fontSize: 18)),
                              selected: icon == e,
                              onSelected: (_) => setSheet(() => icon = e),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text('顏色', style: Theme.of(sheetCtx).textTheme.labelMedium),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in categoryColors)
                      ChoiceChip(
                        key: Key('cat-color-${c.$1}'),
                        label: CircleAvatar(backgroundColor: c.$2, radius: 10),
                        selected: color == c.$1,
                        onSelected: (_) => setSheet(() => color = c.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('cat-save'),
                      onPressed: () {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        try {
                          if (editId != null) {
                            _service.update(
                              editId,
                              name: name,
                              icon: icon,
                              color: color,
                            );
                          } else {
                            _service.create(
                              kind: _kind,
                              name: name,
                              parentId: parentId,
                              icon: icon,
                              color: color,
                            );
                          }
                          Navigator.of(sheetCtx).pop();
                          _refresh();
                        } catch (e) {
                          Navigator.of(sheetCtx).pop();
                          _showSnack('$e');
                        }
                      },
                      child: const Text('儲存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _delete(String id, String name) {
    try {
      _service.delete(id);
      _refresh();
    } catch (e) {
      _showSnack('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref
        .watch(dbProvider)
        .categoriesByKind(_kind)
        .where((c) => c.deletedAt == null)
        .toList();
    final top = categories.where((c) => c.parentId == null).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('分類管理')),
      floatingActionButton: FloatingActionButton(
        key: const Key('cat-add'),
        tooltip: '新增分類',
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('支出')),
              ButtonSegment(value: 'income', label: Text('收入')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ReorderableListView(
              padding: const EdgeInsets.all(12),
              buildDefaultDragHandles: false,
              children: [
                for (final (i, c) in top.indexed)
                  _group(context, c, i, categories),
              ],
              onReorderItem: (from, to) {
                final ids = [for (final c in top) c.id];
                final moved = ids.removeAt(from);
                ids.insert(to, moved);
                _service.applyOrder(_kind, ids);
                _refresh();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 主類別群組（標頭＋子類別縮排列；可折疊——預設展開）。
  Widget _group(
    BuildContext context,
    CategoryRow c,
    int index,
    List<CategoryRow> all,
  ) {
    final tokens = AppTokens.of(context);
    final children = all
        .where((x) => x.deletedAt == null && x.parentId == c.id)
        .toList();
    final open = _isOpen(c.id);
    final names = children.map((x) => x.name).toList();
    final summary = children.isEmpty
        ? '子分類 0'
        : '子分類 ${children.length}：${names.join('、')}';
    return Column(
      key: Key('cat-row-${c.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 09 雛型卡片列：彩色圖示圓＋名稱＋子分類摘要＋操作。
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              ReorderableDragStartListener(
                key: Key('cat-drag-${c.name}'),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, color: tokens.subText),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setState(
                  () => _expanded.contains(c.id)
                      ? _expanded.remove(c.id)
                      : _expanded.add(c.id),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      // 彩色圖示圓（09 雛型）。
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: _colorOf(c.color).withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(categoryEmojiOf(c),
                            style: const TextStyle(fontSize: 20)),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                c.name,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (c.isSystem)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: tokens.track,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text('內建',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: tokens.subText)),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            open && children.isNotEmpty
                                ? '子分類 ${children.length}'
                                : summary,
                            style: TextStyle(
                                fontSize: 11, color: tokens.subText),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                key: Key('cat-sub-${c.name}'),
                tooltip: '新增子分類',
                onPressed: () {
                  // 自動展開（新增後子列可見——f11 S7/S10 語意）。
                  if (!_expanded.contains(c.id)) {
                    setState(() => _expanded.add(c.id));
                  }
                  _openForm(parentId: c.id);
                },
                icon: const Icon(Icons.playlist_add),
              ),
              IconButton(
                key: Key('cat-edit-${c.name}'),
                tooltip: '編輯',
                onPressed: () => _openForm(editId: c.id),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: Key('cat-delete-${c.name}'),
                tooltip: '刪除',
                onPressed: () => _delete(c.id, c.name),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        if (open && children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 40),
            // 子分類排序（PM 決策：子分類也可拖曳）——內嵌非捲動清單，
            // 僅負責同群組內重排（applyOrder 同 kind 同層連續化）。
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              children: [
                for (final (i, sub) in children.indexed)
                  Row(
                    key: Key('cat-sub-row-${sub.name}'),
                    children: [
                      ReorderableDragStartListener(
                        key: Key('cat-sub-drag-${sub.name}'),
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.drag_handle,
                            size: 18,
                            color: tokens.subText,
                          ),
                        ),
                      ),
                      const Icon(Icons.subdirectory_arrow_right, size: 16),
                      const SizedBox(width: 6),
                      // 子類別無圖示（PM 2026-10-24：跟隨主類別）。
                      Text(sub.name),
                      const Spacer(),
                      IconButton(
                        key: Key('cat-edit-${sub.name}'),
                        tooltip: '編輯',
                        onPressed: () => _openForm(editId: sub.id, parentId: c.id),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      IconButton(
                        key: Key('cat-delete-${sub.name}'),
                        tooltip: '刪除',
                        onPressed: () => _delete(sub.id, sub.name),
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
              ],
              onReorderItem: (from, to) {
                final ids = [for (final sub in children) sub.id];
                final moved = ids.removeAt(from);
                ids.insert(to, moved);
                _service.applyOrder(_kind, ids);
                _refresh();
              },
            ),
          ),
      ],
    );
  }

  Color _colorOf(String? name) => categoryColors
      .firstWhere((c) => c.$1 == name, orElse: () => categoryColors.first)
      .$2;
}

/// 分類顏色庫（10 個）。
const List<(String, Color)> categoryColors = [
  ('teal', AppTokens.brandSeed),
  ('amber', Color(0xFFF59E0B)),
  ('red', Color(0xFFD64545)),
  ('purple', Color(0xFF6D4FC4)),
  ('blue', Color(0xFF1D6FD1)),
  ('green', Color(0xFF3B9B46)),
  ('orange', Color(0xFFF97316)),
  ('pink', Color(0xFFEC4899)),
  ('indigo', Color(0xFF6366F1)),
  ('grey', Color(0xFF6B7280)),
];
