import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../application/scan/paper_barcode.dart';
import '../../../application/scan/scan_state.dart';
import '../../../platform/scan/scan_policy.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../../domain/services/invoice_qr_parser.dart';
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

class _NativeCameraScannerState extends ConsumerState<NativeCameraScanner>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  bool _cameraFailed = false; // 啟動雙敗 → 顯示相機錯誤頁（手動重試/匯入）
  String? _lastRaw;
  DateTime? _lastAt;
  Timer? _dedupReset;
  // 兩碼配對（PM 2026-11-20：發票同時有左右兩個 QR——左碼先等右碼
  // 0.8 秒，湊成完整明細再一次入單；逾時才以左碼單獨入單）。
  final Map<String, DateTime> _recent = {}; // 偵測過的條碼 → 時間（3s TTL）

  /// **session 級去重**（PM 2026-11-22：同一張在畫面內不得重複加入——
  /// 舊 1.5s 時窗會讓同一發票每 1.5 秒重加一張＝「關閉連續掃描還是連續掃描」
  /// 的根因之一）。已入單的條碼於本回合（scanDrafts 清空前）不再入單。
  final Set<String> _seenCodes = <String>{};

  /// 每次入單後的掃描暫停（PM 2026-11-22：每掃到一張暫停 0.3 秒——
  /// 連續掃描也是）；確認清單開啟中另有 [scanPausedProvider] 全停。
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  String? _pendingLeft;
  Timer? _pendingTimer;
  String? _hint; // 畫面回饋（偵測到條碼／略過原因）——PM 2026-11-20 診斷用
  Timer? _hintReset;
  int _events = 0; // 偵測事件計數（0＝連條碼都沒進來；持續顯示便診斷）
  // 綠框高亮：最近一幀偵測到的條碼角點（影像座標，相對 _boxImageSize）。
  // 400ms 內無新偵測即清空——對準時 unrestricted 連續回呼，框持續顯示。
  List<List<Offset>> _boxes = const [];
  Size _boxImageSize = Size.zero;
  Timer? _boxReset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.unrestricted, // PM：掃描頻率——最高頻偵測
      facing: CameraFacing.back,
      // PM 2026-11-23：**自管生命週期**（autoStart=false）——修「退出重進
      // 掃描頁黑畫面」：疊頁（完成掃描→確認→返回）同一 controller 正常；
      // 銷毀重建時舊 session 釋放與新 start 競態 → texture 沒幀＝黑畫面。
      // 延遲啟動＋重試見 [_startCamera]。
      autoStart: false,
      // PM 2026-11-21：只掃 QR（發票左右碼）——排除底部一維條碼（Code 39）
      // 被誤判「非發票格式」的雜訊（PM 實測：拿雲端發票掃描誤中一維碼）。
      // 平台策略（scan_policy.dart）：QR（電子發票）＋Code39/128（紙本一維
      // 條碼）同時開啟——模式分流在 _onDetect（不隨模式重建 controller）。
      formats: cameraFormats(detectScanPlatform()),
      // 辨識距離（PM 2026-11-21：「要拉到很近才掃得到」）——提高分析解析度
      // ＋條碼過小自動變焦。mobile_scanner 7.5 文件明載**僅 Android 支援**，
      // iOS/macOS 忽略（上游未開參數；距離天花板屬外掛限制）。
      cameraResolution: const Size(1920, 1080),
      autoZoom: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleStart());
  }

  /// 啟動排程（可取消——dispose 即取消，不留 pending Timer）。
  Timer? _startTimer;
  int _startGen = 0;

  void _scheduleStart() {
    final gen = ++_startGen;
    _startTimer?.cancel();
    // 延遲 300ms：給前一次 teardown（session 釋放）時間——快速退出重進
    // 時舊 release 與新 start 競態 → texture 沒幀＝黑畫面。
    _startTimer = Timer(const Duration(milliseconds: 300), () {
      _startCamera(gen, attempt: 0);
    });
  }

  /// 相機啟動（自管）：失敗重試一次（間隔 500ms）；雙敗 → 相機錯誤頁。
  Future<void> _startCamera(int gen, {required int attempt}) async {
    if (!mounted || gen != _startGen) return;
    try {
      await _controller.start();
      if (mounted) setState(() => _cameraFailed = false);
      return;
    } catch (_) {
      if (attempt == 0 && mounted) {
        _startTimer?.cancel();
        _startTimer = Timer(const Duration(milliseconds: 500), () {
          _startCamera(gen, attempt: 1);
        });
        return;
      }
      if (mounted) setState(() => _cameraFailed = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _startGen++; // 失效排程中的啟動
    _startTimer?.cancel();
    _dedupReset?.cancel();
    _pendingTimer?.cancel();
    _hintReset?.cancel();
    _boxReset?.cancel();
    // 明確 stop（session 釋放）→ dispose——方法通道保序，下次進入的
    // start 不會與本次 release 競態（黑畫面防護）。
    unawaited(_controller.stop().catchError((Object _) {}));
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 前後台：背景停 session（省電＋避免占用）、回前台重啟。
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_cameraFailed) _scheduleStart();
      case AppLifecycleState.inactive ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached ||
          AppLifecycleState.hidden:
        unawaited(_controller.stop().catchError((Object _) {}));
    }
  }

  void _flashHint(String text) {
    if (!mounted) return;
    setState(() => _hint = text);
    _hintReset?.cancel();
    _hintReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  /// 發票字軌號碼樣式（官方規格 v1.9：左碼前 10 碼＝2 大寫字母＋8 數字）。
  /// 定位/分類邏輯集中於 `ImageQrScanner.extractOfficialLeft`（三路徑共用）。
  static final RegExp _invoiceNoPattern = RegExp(r'[A-Z]{2}[0-9]{8}');

  /// 條碼偵測入口（連拍＋去重＋畫面回饋）。
  void _onDetect(BarcodeCapture capture) {
    // 掃描節流（PM 2026-11-22）：確認清單開啟中全停＋每筆入單後 0.3 秒暫停。
    if (ref.read(scanPausedProvider) ||
        DateTime.now().isBefore(_pausedUntil)) {
      return;
    }
    // 綠框高亮＋偵測計數：**所有**偵測到的條碼都畫（含非發票碼——讓使用者
    // 看到「掃到什麼」；角點為影像座標，相對 [BarcodeCapture.size]）。
    if (mounted && !capture.size.isEmpty) {
      final boxes = <List<Offset>>[
        for (final barcode in capture.barcodes)
          if (barcode.corners.length >= 4) List<Offset>.of(barcode.corners),
      ];
      setState(() {
        if (capture.barcodes.isNotEmpty) _events++;
        _boxImageSize = capture.size;
        _boxes = boxes;
      });
      _boxReset?.cancel();
      if (boxes.isNotEmpty) {
        _boxReset = Timer(const Duration(milliseconds: 400), () {
          if (mounted) setState(() => _boxes = const []);
        });
      }
    }
    for (final barcode in capture.barcodes) {
      // Apple Vision 已知行為（PM 2026-11-20：有偵測、無提示＝rawValue 空）：
      // 對 Byte-mode QR 的 payloadStringValue 可能回 null，但位元組有解出。
      // → rawValue 空時退回 rawDecodedBytes/rawBytes 解碼。
      var raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) {
        final Uint8List? bytes = switch (barcode.rawDecodedBytes) {
          DecodedBarcodeBytes(:final bytes) => bytes,
          DecodedVisionBarcodeBytes(:final bytes, :final rawBytes) =>
            bytes ?? rawBytes,
          _ => null,
        };
        if (bytes != null && bytes.isNotEmpty) {
          raw = utf8.decode(bytes, allowMalformed: true).trim();
        }
      }
      if (raw == null || raw.isEmpty) continue;
      // **session 級去重**（PM 2026-11-22）：已入單的條碼（原始內容）本回合
      // 不再入單——同一張在畫面中不重複；**不同發票（不同字串）永不誤擋**。
      if (_seenCodes.contains(raw)) continue;
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

      // 診斷：發票形碼記**完整內容**（fixture 建置用），其他記長度＋開頭 20 字。
      if (_invoiceNoPattern.hasMatch(raw) || raw.startsWith('**')) {
        // ignore: avoid_print
        print('[scan] raw len=${raw.length} full=$raw');
      } else {
        // ignore: avoid_print
        print('[scan] raw len=${raw.length} '
            'head=${raw.substring(0, raw.length > 20 ? 20 : raw.length)}');
      }

      // 模式分流（PM 2026-11-22：電子發票＝QR 配對；紙本發票＝一維條碼
      // 帶發票號碼。平台差異見 scan_policy.dart——各平台成功條件不同，
      // 代碼明確區隔）。
      final mode = ref.read(scanModeProvider);
      if (mode == ScanMode.paper) {
        _handlePaperBarcode(barcode, raw);
        continue;
      }
      if (barcode.format != BarcodeFormat.qrCode) {
        // 電子發票模式掃到一維條碼——引導切模式（不進 _recent 毒害配對）。
        _flashHint('這是一維條碼——紙本發票請切換到「紙本發票」模式');
        continue;
      }

      // 收集近 3 秒條碼（左右兩碼常分幀出現）。
      final now2 = DateTime.now();
      _recent.removeWhere(
          (_, t) => now2.difference(t) > const Duration(seconds: 3));
      _recent[raw] = now2;

      // 官方規格分類（PM 2026-11-22 根因修復）：左碼＝字軌起 77 碼（金額
      // **十六進位**）＋`:` 延伸區（常 90–130 字）；右碼＝`**` 起始。
      // 分類集中 ImageQrScanner——相機/PWA/檔案匯入三路徑同一套規則。
      final texts = _recent.keys.toList();
      String? found;
      for (final t in texts) {
        found = ImageQrScanner.extractOfficialLeft(t);
        if (found != null) break;
      }
      if (found == null) {
        // 三態引導（PM 2026-11-21：區分右碼先到／內容不完整／真非發票碼）。
        if (raw.startsWith('**')) {
          _flashHint('✓ 偵測到右側明細碼——請再對準左側 QR（發票字軌號碼那格）');
        } else if (_invoiceNoPattern.hasMatch(raw)) {
          _flashHint('左側 QR 內容不完整（${raw.length} 字）——請靠近重掃，'
              '或改用「掃描／匯入圖片」');
        } else {
          _flashHint('偵測到 ${barcode.format.name}（${raw.length} 字）'
              '——非發票 QR，請對準發票上的兩個 QR code');
        }
        continue;
      }
      final left = found;
      var right = '';
      for (final t in texts) {
        if (t.startsWith('**')) {
          right = t;
          break;
        }
      }

      if (right.isEmpty) {
        // 只有左碼：等 0.8 秒讓右碼進來；逾時以左碼單獨入單。
        if (_pendingLeft == left) continue;
        _pendingLeft = left;
        _pendingTimer?.cancel();
        _pendingTimer = Timer(const Duration(milliseconds: 800), () {
          _commitLeft(left);
        });
        continue;
      }
      // 左右都到 → 完整明細一次入單；配對失敗（右碼異常）→ 退回左碼入單。
      _pendingTimer?.cancel();
      final draft = ImageQrScanner.draftFromQrTexts([left, right]) ??
          InvoiceQrParser.parseOfficial(left);
      if (draft != null) {
        _commitDraft(draft, '✓ 已加入');
      }
    }
  }

  /// 紙本發票模式：官方一維條碼（Code 39）→ **發票號碼**（2 碼英文＋8 數字）
  /// ＋**年月提示**（期別首月 1 日）；金額/商家由使用者手動輸入
  /// （PM 2026-11-22。macOS 內建相機對紙本小 QR 是光學極限——一維條碼
  /// 較大、Vision 可讀；web 無線性解碼＝scan_policy 分流，走手動開卡）。
  void _handlePaperBarcode(Barcode barcode, String raw) {
    if (barcode.format == BarcodeFormat.qrCode) {
      _flashHint('紙本發票模式：請對準發票下方的一維條碼（數字條碼）');
      return;
    }
    final parsed = parsePaperBarcode(raw);
    if (parsed == null) {
      _flashHint('一維條碼無法辨識（${raw.length} 字）——請靠近重掃或「手動開一筆」');
      return;
    }
    _commitDraft(
      TransactionDraft(
        merchant: const DraftField.none(),
        totalMinor: const DraftField.none(),
        date: DraftField(parsed.dateHint, 0.5),
        invoiceNo: parsed.invoiceNo,
      ),
      '✓ 已讀取發票號碼 ${parsed.invoiceNo}',
    );
  }

  /// 左碼單獨入單（右碼未現）。
  void _commitLeft(String left) {
    final draft = InvoiceQrParser.parseOfficial(left);
    if (draft == null) return;
    _commitDraft(draft, '✓ 已加入（左碼）');
  }

  void _commitDraft(TransactionDraft draft, String note) {
    ref.read(scanDraftsProvider.notifier).add(ScannedItem(draft: draft));
    _seenCodes.addAll(_recent.keys); // 本發票所有條碼：本回合不再重複入單
    _recent.clear();
    _pendingLeft = null;
    _pausedUntil = DateTime.now().add(const Duration(milliseconds: 300));
    final detail = draft.totalMinor.value != null
        ? '${draft.merchant.value ?? '（未辨識商家）'} ${draft.totalMinor.value} 元'
        : '';
    _flashHint('$note${detail.isEmpty ? '' : '：$detail'}——請按「完成掃描」確認');
  }

  /// 紙本發票模式（PM 2026-11-21）：快速手動開一筆——空白確認卡進列，
  /// ReviewPage 補號碼/金額。QR 自動辨識不關（雲端發票證明聯照掃）。
  void _addBlankDraft() {
    ref.read(scanDraftsProvider.notifier)
        .add(ScannedItem(draft: TransactionDraft.blank(DateTime.now())));
    _flashHint('已開空白卡——按「完成掃描」輸入金額與發票號碼');
  }

  @override
  Widget build(BuildContext context) {
    // 回合重置（暫存清空＝新回合）→ seen 集合清空（可再掃同一張）。
    ref.listen(scanDraftsProvider, (prev, next) {
      if (next.isEmpty && _seenCodes.isNotEmpty) _seenCodes.clear();
    });
    // PM 2026-11-23：**辨識區域引導框＝分析窗**（88%×42% 置中偏上——
    // 發票雙 QR 橫排）。Vision regionOfInterest 裁切＝小條碼更靈敏
    // （全畫面分析會稀釋偵測力——PM「容許度變很低」根因）；
    // 框＝引導＝分析範圍，三者一致。寬幅設計：偏移容忍高。
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(builder: (context, constraints) {
        final scanWindow = Rect.fromCenter(
          center: Offset(constraints.biggest.width / 2,
              constraints.biggest.height * 0.42),
          width: constraints.biggest.width * 0.88,
          height: constraints.biggest.height * 0.42,
        );
        if (_cameraFailed) {
          return _CameraError(onFallback: () {
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const ImportPage()));
          });
        }
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
            // 偵測高亮：綠框標記畫面上每個條碼（影像座標 → 預覽座標 cover 映射）。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _BarcodeHighlightPainter(
                    boxes: _boxes,
                    imageSize: _boxImageSize,
                  ),
                ),
              ),
            ),
            // 辨識區域引導框（與分析窗同一 rect——框內＝掃得到）。
            Positioned.fromRect(
              rect: scanWindow,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CornerBracketsPainter(
                      rect: scanWindow, color: Colors.white),
                ),
              ),
            ),
            // 偵測計數（持續顯示——0 次＝連條碼都沒進來；有次數＝格式過濾問題）。
            Positioned(
              left: 8,
              bottom: 8,
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
            // 紙本發票模式：手動開卡入口（PM 2026-11-21）。
            if (ref.watch(scanModeProvider) == ScanMode.paper)
              Positioned(
                left: 0,
                right: 0,
                bottom: 48,
                child: Center(
                  child: FilledButton.icon(
                    key: const Key('scan-manual-entry'),
                    onPressed: _addBlankDraft,
                    icon: const Icon(Icons.receipt_long),
                    label: const Text('手動開一筆'),
                  ),
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

/// 條碼高亮畫筆：影像座標的條碼角點 → 預覽座標（[BoxFit.cover] 映射，
/// 與 MobileScanner 預覽同款縮放：等比取 max、置中裁切），畫綠色多邊形。
/// 角點為透視下的實際四角（不必然矩形），以 `Path.addPolygon` 原樣描繪。
class _BarcodeHighlightPainter extends CustomPainter {
  _BarcodeHighlightPainter({required this.boxes, required this.imageSize});

  /// 每個條碼的角點清單（影像座標；空＝不繪製）。
  final List<List<Offset>> boxes;

  /// 角點所屬的原始影像尺寸（[BarcodeCapture.size]）。
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.isEmpty || boxes.isEmpty) return;
    final scale = math.max(
      size.width / imageSize.width,
      size.height / imageSize.height,
    );
    final offset = Offset(
      (size.width - imageSize.width * scale) / 2,
      (size.height - imageSize.height * scale) / 2,
    );
    final fill = Paint()..color = Colors.green.withValues(alpha: 0.15);
    final stroke = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeJoin = StrokeJoin.round;
    for (final corners in boxes) {
      final path = Path()
        ..addPolygon(
          [for (final p in corners) p * scale + offset],
          true,
        );
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(_BarcodeHighlightPainter oldDelegate) =>
      oldDelegate.imageSize != imageSize ||
      !listEquals(oldDelegate.boxes, boxes);
}

class _CornerBracketsPainter extends CustomPainter {
  _CornerBracketsPainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const len = 26.0;
    const r = 6.0;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final path = Path()
      // 左上
      ..moveTo(rect.left, rect.top + len)
      ..lineTo(rect.left, rect.top + r)
      ..quadraticBezierTo(rect.left, rect.top, rect.left + r, rect.top)
      ..lineTo(rect.left + len, rect.top)
      // 右上
      ..moveTo(rect.right - len, rect.top)
      ..lineTo(rect.right - r, rect.top)
      ..quadraticBezierTo(rect.right, rect.top, rect.right, rect.top + r)
      ..lineTo(rect.right, rect.top + len)
      // 右下
      ..moveTo(rect.right, rect.bottom - len)
      ..lineTo(rect.right, rect.bottom - r)
      ..quadraticBezierTo(rect.right, rect.bottom, rect.right - r, rect.bottom)
      ..lineTo(rect.right - len, rect.bottom)
      // 左下
      ..moveTo(rect.left + len, rect.bottom)
      ..lineTo(rect.left + r, rect.bottom)
      ..quadraticBezierTo(rect.left, rect.bottom, rect.left, rect.bottom - r)
      ..lineTo(rect.left, rect.bottom - len);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerBracketsPainter old) => old.rect != rect;
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
