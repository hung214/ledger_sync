import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import 'review_page.dart';

/// 相簿/檔案匯入（FR-S6 桌面/無相機路徑）：檔案選擇→OCR→確認清單。
/// 匯入管線經 [importPipelineProvider] 注入（生產：平台檔案選擇器＋OCR 引擎；
/// 測試：T-H6 fixture 回放）——無相機裝置不因缺相機而功能缺失（S3.9）。
class ImportPage extends ConsumerWidget {
  const ImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('匯入圖片')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined, size: 56),
            const SizedBox(height: 12),
            const Text('選擇發票／收據圖片——自動辨識 QR 後逐張確認入帳'),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('import-pick'),
              onPressed: () => _pickAndReview(context, ref),
              icon: const Icon(Icons.upload_file),
              label: const Text('選擇圖片檔'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndReview(BuildContext context, WidgetRef ref) async {
    final item = await ref.read(importPipelineProvider)();
    if (item == null || !context.mounted) return; // 使用者取消
    ref.read(scanDraftsProvider.notifier).reset();
    ref.read(scanDraftsProvider.notifier).add(item);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReviewPage(items: [item])),
    );
  }
}
