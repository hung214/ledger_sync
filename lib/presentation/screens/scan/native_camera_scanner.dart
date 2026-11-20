import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../application/scan/scan_state.dart';
import '../../../platform/scan/image_qr_scan.dart';
import 'import_page.dart';

/// 原生即時相機掃描（SP-2b；PM 2026-11-20 優先）——mobile_scanner
/// 支援 **Android／iOS／macOS**（web 不走此路徑：WebCameraScanPage，
/// F14 getUserMedia 版本）。
///
/// - 解析重用 F03 BE 管線：`ImageQrScanner.draftFromQrTexts`
///   （左碼 77 碼＋右碼明細）；**無法辨識的 QR（如網址）略過**，不產生空白卡。
/// - 連拍去重：同一條碼 1.5 秒內重複出現 → 略過（同 web 版語意）。
/// - photoBytes＝null（附件來源目前為檔案匯入；相機截幀屬後續增強）。
class NativeCameraScanner extends ConsumerStatefulWidget {
  const NativeCameraScanner({super.key});

  @override
  ConsumerState<NativeCameraScanner> createState() =>
      _NativeCameraScannerState();
}

class _NativeCameraScannerState extends ConsumerState<NativeCameraScanner> {
  late final MobileScannerController _controller;
  String? _lastRaw;
  DateTime? _lastAt;
  Timer? _dedupReset;
  String? _hint; // 畫面回饋（偵測到條碼／略過原因）——PM 2026-11-20 診斷用
  Timer? _hintReset;
  int _events = 0; // 偵測事件計數（0＝連條碼都沒進來；持續顯示便診斷）

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.unrestricted, // PM：掃描頻率——最高頻偵測
      facing: CameraFacing.back,
      autoStart: true,
    );
  }

  @override
  void dispose() {
    _dedupReset?.cancel();
    _hintReset?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _flashHint(String text) {
    if (!mounted) return;
    setState(() => _hint = text);
    _hintReset?.cancel();
    _hintReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  /// 條碼偵測入口（連拍＋去重＋畫面回饋）。
  void _onDetect(BarcodeCapture capture) {
    if (capture.barcodes.isNotEmpty && mounted) {
      setState(() => _events++);
    }
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      final now = DateTime.now();
      // 同一條碼 1.5s 內重複 → 略過（對準同一張發票會連續回呼）。
      if (raw == _lastRaw &&
          _lastAt != null &&
          now.difference(_lastAt!) < const Duration(milliseconds: 1500)) {
        continue;
      }
      _lastRaw = raw;
      _lastAt = now;
      _dedupReset?.cancel();
      _dedupReset = Timer(const Duration(milliseconds: 1500), () {
        _lastRaw = null;
        _lastAt = null;
      });

      final draft = ImageQrScanner.draftFromQrTexts([raw]);
      if (draft == null) {
        // 非發票 QR（網址等）→ 略過，但**畫面回饋**（診斷：偵測有到、格式不符）
        _flashHint('偵測到 QR（${raw.length} 字）——非發票格式，已略過');
        continue;
      }
      ref.read(scanDraftsProvider.notifier).add(ScannedItem(draft: draft));
      _flashHint('✓ 已加入：${draft.merchant.value ?? '（未辨識商家）'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    // PM 2026-11-20：區域太大 → 中央 70% 掃描窗（Vision 只分析此區，
    // 減噪＋聚焦；7.x scanWindow＝widget 內邏輯座標，官方範例同款）。
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(builder: (context, constraints) {
        final scanWindow = Rect.fromCenter(
          center: constraints.biggest.center(Offset.zero),
          width: constraints.biggest.width * 0.7,
          height: constraints.biggest.height * 0.7,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              scanWindow: scanWindow,
              errorBuilder: (context, error) => _CameraError(onFallback: () {
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ImportPage()));
              }),
            ),
            // 掃描窗框線（讓使用者知道對準範圍）
            Positioned.fromRect(
              rect: scanWindow,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            // 偵測計數（持續顯示——0 次＝連條碼都沒進來；有次數＝格式過濾問題）
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('偵測 $_events 次',
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
            if (_hint != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_hint!,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12)),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// 相機錯誤（權限被拒／無相機）——訊息＋回退檔案匯入（不離開流程）。
class _CameraError extends StatelessWidget {
  const _CameraError({required this.onFallback});

  final VoidCallback onFallback;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_outlined, size: 48),
          const SizedBox(height: 12),
          const Text('相機無法啟用（權限或裝置限制）'),
          const Text('可改用檔案匯入：選發票照片掃描 QR',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('camera-error-fallback'),
            onPressed: onFallback,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('從檔案匯入'),
          ),
        ],
      ),
    );
  }
}
