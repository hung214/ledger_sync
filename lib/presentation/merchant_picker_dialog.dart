import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';

/// 商家選擇器（T8，PM 2026-11-22：商家「類別同款」**可選可增**）——
/// 直接輸入（即＝新增）＋**最近使用**建議 chips（交易 DISTINCT merchant，
/// 免新表）。快記／確認卡共用。回傳商家名（null＝取消）。
Future<String?> showMerchantPicker(
  BuildContext context,
  WidgetRef ref, {
  String? initial,
}) {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('選擇商家'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('merchant-input'),
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: '商家名稱（可直接輸入新商家）'),
          ),
          const SizedBox(height: 8),
          Consumer(builder: (context, ref, _) {
            final merchants = ref.watch(recentMerchantsProvider);
            if (merchants.isEmpty) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in merchants)
                    ActionChip(
                      key: Key('merchant-chip-$m'),
                      label: Text(m),
                      onPressed: () => Navigator.of(dialogCtx).pop(m),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消')),
        FilledButton(
            key: const Key('merchant-pick-save'),
            onPressed: () => Navigator.of(dialogCtx).pop(ctrl.text.trim()),
            child: const Text('確定')),
      ],
    ),
  );
}
