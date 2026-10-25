import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/providers.dart';
import '../../../data/sqlite/app_database.dart';
import '../../category_display.dart';

/// 分類選擇彈窗結果（PM 2026-10-24）。
sealed class CategoryPick {
  const CategoryPick();
}

/// 選定分類（主類別或子分類）。
class CategoryPicked extends CategoryPick {
  const CategoryPicked(this.categoryId);
  final String categoryId;
}

/// 要求「＋即建即選」（新增主類別／子類別）。
class CategoryAddRequested extends CategoryPick {
  const CategoryAddRequested({required this.asSub, this.parentId});
  final bool asSub;
  final String? parentId;
}

/// 顯示「分類選擇」彈窗：**左欄最上方「⭐ 常用類別」／左主類別／右子類別**
/// （PM 2026-10-25 定稿；原「上方常用 chips」已移除）。
///
/// - 點「⭐ 常用類別」→ 右欄列出**常用（MRU）類別文字**（主類別＝名稱；
///   子類別＝主類別 emoji ＋ 子類別名）——點擊即選取。
/// - 左欄主類別 → 右欄該主類別之子類別；「（不分類）」＝只記主類別。
/// - 手機與 PC 共用同一元件（RWD 單碼庫）。回傳 null＝取消（不變更）。
Future<CategoryPick?> showCategoryPicker(
  BuildContext context,
  WidgetRef ref, {
  String kind = 'expense',
  String? selectedId,
}) {
  return showDialog<CategoryPick>(
    context: context,
    builder: (_) =>
        _CategoryPickerDialog(kind: kind, selectedId: selectedId),
  );
}

class _CategoryPickerDialog extends ConsumerStatefulWidget {
  const _CategoryPickerDialog({this.kind = 'expense', this.selectedId});

  final String kind;
  final String? selectedId;

  @override
  ConsumerState<_CategoryPickerDialog> createState() =>
      _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends ConsumerState<_CategoryPickerDialog> {
  /// 「⭐ 常用類別」在左欄的識別碼（非真實類別 id）。
  static const String freqId = '__freq__';

  String? _mainId;

  @override
  void initState() {
    super.initState();
    final cats = ref.read(dbProvider).categoriesByKind(widget.kind);
    final sel = widget.selectedId;
    CategoryRow? selected;
    for (final c in cats) {
      if (c.id == sel) selected = c;
    }
    // 選中子分類 → 左欄高亮其所屬主類別；選中主類別 → 本身。
    // 未選任何分類 → 保持 null，由 build 依「常用是否有紀錄」決定預設欄
    // （PM 2026-10-25：有常用 → 預設 ⭐ 常用類別；否則首個主類別）。
    _mainId = selected?.parentId ?? selected?.id;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cats = ref.watch(dbProvider).categoriesByKind(widget.kind);
    final mains = [for (final c in cats) if (c.parentId == null) c];
    final byId = categoryIndex(cats);
    // 常用（MRU 前 10；只留本模式 kind 之分類，去重由 provider 負責）。
    final recent = [
      for (final id in ref.watch(recentCategoryIdsProvider))
        if (byId[id] != null) byId[id]!,
    ];
    // 有效主欄：使用者選擇 ??
    //   有常用 → ⭐ 常用類別 : 首個主類別（PM 2026-10-25 預設）。
    final effMain = _mainId ??
        (recent.isNotEmpty
            ? freqId
            : (mains.isEmpty ? null : mains.first.id));
    final isFreq = effMain == freqId;
    final subs = isFreq
        ? const <CategoryRow>[]
        : [for (final c in cats) if (c.parentId == effMain) c];

    Widget head(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Text(s, style: text.labelSmall?.copyWith(color: scheme.outline)),
        );

    Widget row({
      required Key key,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) =>
        InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: selected ? scheme.primaryContainer : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(label,
                style: text.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: selected ? scheme.onPrimaryContainer : null,
                    fontWeight: selected ? FontWeight.w700 : null)),
          ),
        );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
              child: Text('選擇分類',
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text('點左欄主類別 → 右欄選子類別（不選＝只記主類別）',
                  style: text.labelSmall?.copyWith(color: scheme.outline)),
            ),
            Flexible(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 156,
                    // 非懶載清單（SingleChildScrollView+Column）：長清單（15+ 主類別、
                    // 多子類別）全部建出——避免底部項找不到/點不到（PM 2026-10-22 教訓）。
                    child: SingleChildScrollView(
                      key: const Key('picker-mains'),
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        head('主類別'),
                        // ⭐ 常用類別（PM 2026-10-25）——置於主類別清單**最上方**。
                        if (recent.isNotEmpty)
                          row(
                            key: const Key('picker-freq'),
                            label: '⭐ 常用類別',
                            selected: isFreq,
                            onTap: () => setState(() => _mainId = freqId),
                          ),
                        InkWell(
                          key: const Key('picker-add-main'),
                          onTap: () => Navigator.of(context).pop(
                              const CategoryAddRequested(asSub: false)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Text('＋ 新增主類別',
                                style: text.bodySmall
                                    ?.copyWith(color: scheme.primary)),
                          ),
                        ),
                        for (final m in mains)
                          row(
                            key: Key('picker-main-${m.name}'),
                            label: categoryLabelOf(m, byId: byId),
                            selected: m.id == effMain,
                            onTap: () => setState(() => _mainId = m.id),
                          ),
                          ]),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('picker-subs'),
                      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: isFreq
                              // ⭐ 常用類別：右欄＝常用類別**文字**清單
                              // （主類別＝名稱；子類別＝主類別 emoji ＋子名）。
                              ? [
                                  head('常用類別'),
                                  for (final c in recent)
                                    row(
                                      key: Key('picker-freq-${c.name}'),
                                      label: c.parentId == null
                                          ? c.name
                                          : categoryLabelOf(c, byId: byId),
                                      selected: c.id == widget.selectedId,
                                      onTap: () => Navigator.of(context)
                                          .pop(CategoryPicked(c.id)),
                                    ),
                                ]
                              : [
                                  head('子類別'),
                                  InkWell(
                                    key: const Key('picker-add-sub'),
                                    onTap: effMain == null
                                        ? null
                                        : () => Navigator.of(context).pop(
                                            CategoryAddRequested(
                                                asSub: true, parentId: effMain)),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          10, 8, 10, 8),
                                      child: Text('＋ 新增子類別',
                                          style: text.bodySmall?.copyWith(
                                              color: scheme.primary)),
                                    ),
                                  ),
                                  if (effMain != null)
                                    row(
                                      key: const Key('picker-sub-none'),
                                      label: '（不分類）',
                                      selected: false,
                                      onTap: () => Navigator.of(context)
                                          .pop(CategoryPicked(effMain)),
                                    ),
                                  for (final s in subs)
                                    row(
                                      key: Key('picker-sub-${s.name}'),
                                      // 子類別無圖示（PM 2026-10-24；左欄主類別已載圖示）。
                                      label: s.name,
                                      selected: s.id == widget.selectedId,
                                      onTap: () => Navigator.of(context)
                                          .pop(CategoryPicked(s.id)),
                                    ),
                                ]),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('picker-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
