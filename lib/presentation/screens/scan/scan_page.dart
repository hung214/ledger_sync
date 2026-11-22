import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import 'import_page.dart';
import 'native_camera_scanner.dart';
import 'web_camera_scan.dart';
import 'review_page.dart';

/// 掃描入口路由（FR-S6）：相機可用 → 掃描頁；無相機裝置 → 相簿/檔案匯入。
/// F14（PWA）：**Web → 即時相機掃描頁**（getUserMedia；相機不可用時頁內回退檔案匯入）。
Future<void> openScanFlow(BuildContext context, WidgetRef ref) {
  if (kIsWeb) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const WebCameraScanPage()));
  }
  final hasCamera = ref.read(cameraAvailableProvider);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => hasCamera ? const ScanPage() : const ImportPage(),
    ),
  );
}

/// 掃描頁（FR-S6/S7）：狀態機——權限閘→掃描中（計數＋縮圖列）→完成掃描
/// →確認清單（ReviewPage）。
///
/// 相機預覽區為行動端 mobile_scanner 接線點（SP-2b；M4 FE 情境以解析結果
/// 注入 scanDraftsProvider 驗 UI 流程，dsl「影像回放注入」——掃描器回呼
/// 契約＝`scanDraftsProvider.add`）。
class ScanPage extends ConsumerWidget {
  const ScanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permission = ref.watch(cameraPermissionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('掃描')),
      body: switch (permission) {
        CameraPermissionState.notDetermined => const _PermissionGate(),
        CameraPermissionState.denied => const _PermissionDenied(),
        CameraPermissionState.granted => const _ScanningBody(),
      },
    );
  }
}

/// 權限請求（F03-FE S2：未授權 → 請求 → 拒絕 → 引導，不離開 App）。
class _PermissionGate extends ConsumerWidget {
  const _PermissionGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.photo_camera_outlined, size: 56),
          const SizedBox(height: 12),
          const Text('權限請求', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('掃描發票需要相機權限'),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('perm-allow'),
            onPressed: () => ref.read(cameraPermissionProvider.notifier).allow(),
            child: const Text('允許'),
          ),
          TextButton(
            key: const Key('perm-deny'),
            onPressed: () => ref.read(cameraPermissionProvider.notifier).deny(),
            child: const Text('拒絕'),
          ),
        ],
      ),
    );
  }
}

/// 權限拒絕後引導（FR-S6：有恢復路徑、不離開 App）。
class _PermissionDenied extends StatelessWidget {
  const _PermissionDenied();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_outlined, size: 56),
          const SizedBox(height: 12),
          const Text('前往設定開啟權限',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('相機權限已被拒絕——請至系統設定開啟後重試'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}

/// 掃描中（FR-S7 連拍）：模式切換＋相機預覽＋已掃計數＋連續掃描開關
/// ＋縮圖列＋完成掃描。
class _ScanningBody extends ConsumerStatefulWidget {
  const _ScanningBody();

  @override
  ConsumerState<_ScanningBody> createState() => _ScanningBodyState();
}

class _ScanningBodyState extends ConsumerState<_ScanningBody> {
  bool _navigating = false;

  /// 推入確認清單：**掃描暫停**（scanPausedProvider——PM 2026-11-22：
  /// 確認期間不得繼續偵測＝修「關閉連續掃描還是連續掃描」），返回後恢復。
  Future<void> _openReview(List<ScannedItem> items) async {
    if (_navigating) return;
    _navigating = true;
    ref.read(scanPausedProvider.notifier).set(true);
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReviewPage(items: List.of(items))));
    if (!mounted) return;
    ref.read(scanPausedProvider.notifier).set(false);
    _navigating = false;
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(scanDraftsProvider);
    final mode = ref.watch(scanModeProvider);
    // 連續掃描關閉（PM 2026-11-21）：掃到**第一張**（QR 命中或紙本手動開卡）
    // → 自動進確認清單（掃描同時暫停）；開啟＝連拍累積（FR-S7 預設）。
    ref.listen(scanDraftsProvider, (prev, next) {
      if (!ref.read(continuousScanProvider) &&
          (prev == null || prev.isEmpty) &&
          next.isNotEmpty) {
        _openReview(next);
      }
    });
    return Column(
      children: [
        // 掃描模式（PM 2026-11-21）：電子發票＝即時 QR；紙本發票＝快速手動開卡。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SegmentedButton<ScanMode>(
            key: const Key('scan-mode-toggle'),
            segments: const [
              ButtonSegment(
                  value: ScanMode.eInvoice,
                  icon: Icon(Icons.qr_code_scanner),
                  label: Text('電子發票 QR')),
              ButtonSegment(
                  value: ScanMode.paper,
                  icon: Icon(Icons.receipt_long),
                  label: Text('紙本發票')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) =>
                ref.read(scanModeProvider.notifier).set(selection.first),
          ),
        ),
        // 原生即時相機（SP-2b 完成：mobile_scanner——Android/iOS/macOS）。
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(children: [
              const Positioned.fill(child: NativeCameraScanner()),
              const Positioned(
                left: 0,
                right: 0,
                top: 8,
                child: Center(
                  child: _AimHint(),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text('已掃 ${items.length} 張',
                  key: const Key('scan-count'),
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              const Text('連續掃描', style: TextStyle(fontSize: 13)),
              Switch(
                key: const Key('scan-continuous-toggle'),
                value: ref.watch(continuousScanProvider),
                onChanged: (v) =>
                    ref.read(continuousScanProvider.notifier).set(v),
              ),
            ],
          ),
        ),
        if (items.isNotEmpty)
          SizedBox(
            height: 96,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              children: [
                for (var i = 0; i < items.length; i++)
                  _Thumbnail(
                    item: items[i],
                    index: i,
                    onTap: () => _openReview([items[i]]),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('scan-finish'),
              onPressed: items.isEmpty
                  ? null
                  : () => _openReview(items),
              child: const Text('完成掃描'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 掃描縮圖（FR-S7：即時縮圖列表；**點擊＝單張編輯**——PM 2026-11-22）。
class _Thumbnail extends StatelessWidget {
  const _Thumbnail(
      {required this.item, required this.index, required this.onTap});

  final ScannedItem item;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final draft = item.draft;
    final total = draft.totalMinor.value;
    return GestureDetector(
      key: Key('scan-thumbnail-$index'),
      onTap: onTap,
      child: Container(
        width: 88,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  draft.merchant.value ?? '（未辨識）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Icon(Icons.edit_outlined,
                  size: 12, color: Theme.of(context).colorScheme.outline),
            ]),
            Text(total == null ? '—' : '$total 元',
                style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}


/// 掃描提示（半透明膠囊——覆蓋在預覽上）。
class _AimHint extends StatelessWidget {
  const _AimHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text('對準發票 QR code（自動辨識；重複掃描自動略過）',
          style: TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}
