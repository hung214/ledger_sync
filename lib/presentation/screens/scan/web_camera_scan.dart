import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../../platform/scan/camera_stream.dart';
import '../../../platform/scan/image_qr_scan.dart';
import 'import_page.dart';
import 'review_page.dart';

/// 解碼函式 provider（測試可覆寫；預設＝**相機幀分層解碼**——輕量 3 區 →
/// 中央變焦 → 四象限，回傳草稿＋**解出的原始文字**（去重 key 用））。
final webCameraDecodeProvider = Provider<
        ({TransactionDraft? draft, List<String> texts})? Function(Uint8List)>(
    (ref) => (bytes) => ImageQrScanner().draftFromCameraFrame(bytes));

/// 相機控制器 provider（測試可覆寫 fake）。
final webCameraControllerProvider =
    Provider<CameraStreamController>((ref) => createCameraController());

/// 部署版本（dart-define 帶入；掃描診斷面板顯示——確認更新已生效）。
const String kWebScanAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// **PWA 即時相機掃描**（F14；PM 2026-11-17 決策 A）。
///
/// 流程：開相機（getUserMedia 後鏡頭）→ **自動解碼迴圈**（每 1.2s 取幀→zxing2）
/// → 命中發票 QR → 加入草稿（同張去重）→ 「完成掃描」→ 確認清單（ReviewPage，
/// 與檔案匯入同一流程）。相機不可用（拒絕/無 https）→ **回退檔案匯入**。
///
/// 測試 keys：`webcam-preview`／`webcam-count`／`webcam-done`／`webcam-fallback-file`。
class WebCameraScanPage extends ConsumerStatefulWidget {
  const WebCameraScanPage({super.key});

  @override
  ConsumerState<WebCameraScanPage> createState() => _WebCameraScanPageState();
}

class _WebCameraScanPageState extends ConsumerState<WebCameraScanPage> {
  _CamState _state = _CamState.starting;
  String? _error;
  Widget? _preview;
  late final CameraStreamController _controller =
      ref.read(webCameraControllerProvider);
  Timer? _loop;
  /// **session 級去重＝條碼原始內容**（PM 2026-11-22 修「換一張發票就
  /// 掃描不到」：舊指紋 total|date|merchant 會把**同店家/同金額/同日期的
  /// 不同發票**誤擋——不同發票＝不同字串，永不誤擋；同一張在畫面中不重複）。
  final Set<String> _seenCodes = <String>{};

  /// **跨 tick 累積窗**（PM 2026-11-23：單碼好辨識、雙碼難——左碼/右碼
  /// 常分 tick 或分區域解出；APP 有 3 秒累積窗、PWA 原本沒有）。
  final Map<String, DateTime> _recentTexts = {};

  /// 已入單的**左碼**（發票身分）——同一張不重複加入。
  final Set<String> _committedLeftCodes = <String>{};

  String? _hint; // 畫面提示（只掃到明細碼等）——與 APP 同款
  Timer? _hintReset;

  void _flashHint(String text) {
    if (!mounted) return;
    setState(() => _hint = text);
    _hintReset?.cancel();
    _hintReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _hint = null);
    });
  }
  int _addedFromThisSession = 0;
  // 診斷面板（PM 2026-11-21「無法正確掃描」定位用）：
  int _frames = 0; // 取幀計數
  String _frameInfo = '—'; // 最近取幀狀態（大小／無畫面）
  int _decodeHits = 0; // 解碼命中次數
  bool _decoding = false; // 解碼中跳過新幀（同步解碼塞主執行緒——疊加即卡死）

  /// 每次命中後的掃描暫停（PM 2026-11-22：每掃到一張暫停 0.3 秒）＋
  /// 確認清單開啟中全停（[scanPausedProvider]）——與 APP 同款節流。
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _decodeMs = 0; // 最近一次解碼耗時（面板顯示——行動裝置效能定位）
  double _zoom = 0; // 0=1×、0.5=2×、1.0=3×
  bool _zoomSupported = false;

  /// 原生偵測器命中的條碼框（正規化——綠框高亮）。
  final ValueNotifier<({List<Rect> boxes, Size frameSize})?>
      _nativeBoxesNotifier = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    // reset＋start 皆有 setState/provider 修改——必須在首幀後（避免 build 中改 provider）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(scanDraftsProvider.notifier).reset();
      _start();
    });
  }

  Future<void> _start() async {
    setState(() => _state = _CamState.starting);
    try {
      final preview = await _controller.start();
      if (!mounted) return;
      _zoomSupported = _controller.zoomSupported;
      if (mounted) {
        setState(() {
          _preview = preview;
          _state = _CamState.live;
        });
      }
      // 節奏自適應（PM 2026-11-23）：原生偵測器快 → 700ms；zxing2 → 1200ms。
      _loop = Timer.periodic(_controller.decodeInterval, (_) => _tryDecode());
    } on CameraUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.failed;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.failed;
        _error = '相機啟動失敗：$e';
      });
    }
  }

  Future<void> _tryDecode() async {
    if (_state != _CamState.live || _decoding) return;
    if (ref.read(scanPausedProvider) ||
        DateTime.now().isBefore(_pausedUntil)) {
      return;
    }
    _decoding = true;
    final sw = Stopwatch()..start();
    Uint8List? photoBytes;
    TransactionDraft? draft;
    var texts = const <String>[];
    // **瀏覽器原生偵測器優先**（T10，PM 2026-11-22「Mac PWA 還是無法讀取」
    // 主修法）：BarcodeDetector API 直接吃 video 全解析度幀——無 canvas/
    // JPEG 轉檔損耗、品質遠勝 zxing2；不支援的瀏覽器 → 既有 zxing2 後備。
    if (_controller.hasNativeBarcodeDetector) {
      texts = await _controller.detectNativeBarcodes();
      if (mounted) {
        setState(() {
          _frames++;
          _frameInfo = _controller.resolutionInfo;
        });
      }
      _nativeBoxesNotifier.value = _controller.lastNativeBoxes;
      if (texts.isNotEmpty) {
        draft = ImageQrScanner.draftFromQrTexts(texts);
      }
    } else {
      final bytes = await _controller.captureFrame();
      if (mounted) {
        setState(() {
          _frames++;
          _frameInfo = bytes == null
              ? '無畫面'
              : '${_controller.resolutionInfo} · ${bytes.length} B';
        });
      }
      if (bytes != null) {
        photoBytes = bytes;
        final result = ref.read(webCameraDecodeProvider)(bytes);
        draft = result?.draft;
        texts = result?.texts ?? const [];
      }
    }
    sw.stop();
    _decoding = false;
    if (mounted) setState(() => _decodeMs = sw.elapsedMilliseconds);
    // **跨 tick 累積窗**（3 秒）——雙碼常分 tick 解出（PM 2026-11-23）。
    if (texts.isNotEmpty) {
      final now2 = DateTime.now();
      // 新左碼出現 → 重置累積窗（換發票——避免 A 張左碼混 B 張右碼）。
      String? newLeft;
      for (final t in texts) {
        final l = ImageQrScanner.extractOfficialLeft(t);
        if (l != null) {
          newLeft = l;
          break;
        }
      }
      if (newLeft != null) {
        String? oldLeft;
        for (final t in _recentTexts.keys) {
          final l = ImageQrScanner.extractOfficialLeft(t);
          if (l != null) {
            oldLeft = l;
            break;
          }
        }
        if (oldLeft != null && oldLeft != newLeft) {
          _recentTexts.clear();
        }
      }
      _recentTexts.removeWhere((_, t) =>
          now2.difference(t) > const Duration(seconds: 3));
      for (final t in texts) {
        _recentTexts[t] = now2;
      }
    }
    final accumulated = _recentTexts.keys.toList();
    if (accumulated.isEmpty) return;
    if (mounted) setState(() => _decodeMs = sw.elapsedMilliseconds);
    // 去重＝**條碼原始內容**（不同發票永不誤擋——PM 2026-11-22 修復）。
    if (accumulated.every(_seenCodes.contains)) return; // 同一張還在畫面中
    // 累積優先：右碼補齊後合併成完整明細（draft 來自分層/累積）。
    final merged = ImageQrScanner.draftFromQrTexts(accumulated) ?? draft;
    if (merged == null) {
      // 只有右碼（明細碼）——引導對準左側（與 APP 同款提示）。
      if (accumulated.any((t) => t.startsWith('**'))) {
        _flashHint('✓ 偵測到右側明細碼——請再對準左側 QR（發票號那格）');
      }
      return;
    }
    if (mounted) setState(() => _decodeHits++);
    // 左碼＝發票身分：已入單的發票不重複加入。
    String? leftCode;
    for (final t in accumulated) {
      final l = ImageQrScanner.extractOfficialLeft(t);
      if (l != null) {
        leftCode = l;
        break;
      }
    }
    if (leftCode != null && _committedLeftCodes.contains(leftCode)) {
      return;
    }
    ref.read(scanDraftsProvider.notifier).add(
        ScannedItem(draft: merged, photoBytes: photoBytes));
    for (final t in accumulated) {
      _seenCodes.add(t);
    }
    if (leftCode != null) _committedLeftCodes.add(leftCode);
    if (mounted) setState(() => _addedFromThisSession++);
    _pausedUntil = DateTime.now().add(const Duration(milliseconds: 300));
  }

  bool _navigating = false;

  /// 推入確認清單：**掃描暫停**（確認期間不得繼續偵測），返回後恢復。
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

  Future<void> _finish() async {
    _loop?.cancel();
    final items = ref.read(scanDraftsProvider).toList();
    await _openReview(items);
    if (!mounted) return;
    ref.read(scanDraftsProvider.notifier).reset();
    setState(() {
      _addedFromThisSession = 0;
      _seenCodes.clear();
    });
    _loop = Timer.periodic(
        _controller.decodeInterval, (_) => _tryDecode()); // 繼續掃
  }

  /// 紙本發票手動開卡（PM 2026-11-22：與 APP 同款——加入暫存清單，
  /// 「完成掃描」統一進確認清單；金額/日期/商家/發票號皆手動輸入）。
  void _addBlankDraft() {
    ref.read(scanDraftsProvider.notifier)
        .add(ScannedItem(draft: TransactionDraft.blank(DateTime.now())));
  }

  void _fallbackToFile() {
    _loop?.cancel();
    _controller.dispose();
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => const ImportPage()));
  }

  @override
  void dispose() {
    _loop?.cancel();
    _hintReset?.cancel();
    _nativeBoxesNotifier.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 回合重置（暫存清空＝新回合）→ seen 清空（可再掃同一張）；
    // 連續掃描關閉（預設）：掃到第一張 → 自動進確認清單（掃描暫停）。
    ref.listen(scanDraftsProvider, (prev, next) {
      if (next.isEmpty && _seenCodes.isNotEmpty) {
        _seenCodes.clear();
      }
      if (!ref.read(continuousScanProvider) &&
          (prev == null || prev.isEmpty) &&
          next.isNotEmpty) {
        _openReview(next);
      }
    });
    final drafts = ref.watch(scanDraftsProvider);
    final count = drafts.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('掃描發票'),
        actions: [
          if (_state == _CamState.live)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('已掃 $count 張',
                    key: const Key('webcam-count'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
        ],
      ),
      body: switch (_state) {
        _CamState.starting => const Center(child: CircularProgressIndicator()),
        _CamState.failed => _buildFailed(context),
        _CamState.live => _buildLive(context),
      },
    );
  }

  Widget _buildLive(BuildContext context) {
    final drafts = ref.watch(scanDraftsProvider);
    final count = drafts.length;
    final mode = ref.watch(scanModeProvider);
    return Column(
      children: [
        // 掃描模式（PM 2026-11-22：與 APP 同款按鈕方式——**置頂**）。
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
        // 預覽：**contain 幾何**（PM 2026-11-23「放很大、比例不對、顆粒
        // 清楚」——cover 在預覽區比例不合時大裁切＋放大）。video 完整
        // 顯示（黑邊背景），引導框/綠框/按鈕全部定位在 videoRect 內。
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(builder: (context, constraints) {
              final aspect = _controller.videoAspect ?? 16 / 9;
              final videoRect = _containRect(constraints.biggest, aspect);
              final aimRect = _aimFrameRect(videoRect);
              return Stack(children: [
                // 影像（**全幅平台檢視——已知可用結構**；object-fit: contain
                // 會把影像內容縮在 videoRect＝與疊層幾何一致）。
                Positioned.fill(
                  child: KeyedSubtree(
                      key: const Key('webcam-preview'), child: _preview!),
                ),
                if (drafts.isNotEmpty)
                  Positioned(
                    left: videoRect.left + 12,
                    top: videoRect.top + 12,
                    child: Chip(
                      avatar: const Icon(Icons.check_circle,
                          color: Colors.green, size: 18),
                      label: Text('已加入 ${drafts.length} 張'),
                    ),
                  ),
                // 切換鏡頭（PM 2026-11-21）。
                Positioned(
                  right: videoRect.left + 12,
                  top: videoRect.top + 12,
                  child: IconButton(
                    key: const Key('webcam-switch-camera'),
                    tooltip: '切換鏡頭',
                    onPressed: () => _controller.switchCamera(),
                    icon: const Icon(Icons.cameraswitch),
                    color: Colors.white,
                  ),
                ),
                // 辨識區域引導框（四角括號——與 APP 同款；純視覺）。
                Positioned.fromRect(
                  rect: aimRect,
                  child: IgnorePointer(
                      child: CustomPaint(
                          painter: _CornerBrackets(rect: aimRect))),
                ),
                // 原生偵測器命中 → 綠框（正規化座標 → videoRect 映射）。
                ValueListenableBuilder(
                  valueListenable: _nativeBoxesNotifier,
                  builder: (context, boxes, _) =>
                      boxes == null || boxes.boxes.isEmpty
                          ? const SizedBox.shrink()
                          : Positioned.fromRect(
                              rect: videoRect,
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _NativeBoxPainter(
                                      boxes: boxes.boxes,
                                      videoRect: videoRect),
                                ),
                              ),
                            ),
                ),
                // 變焦按鈕（PM 2026-11-23：小/遠條碼——變焦取代靠近）。
                if (_zoomSupported)
                  Positioned(
                    right: videoRect.left + 8,
                    top: videoRect.top + 48,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final (label, z) in const [
                          ('1×', 0.0),
                          ('2×', 0.5),
                          ('3×', 1.0),
                        ])
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 2),
                            child: GestureDetector(
                              onTap: () {
                                setState(() => _zoom = z);
                                unawaited(_controller.setZoom(z));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _zoom == z
                                      ? Colors.white
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(label,
                                    style: TextStyle(
                                        color: _zoom == z
                                            ? Colors.black
                                            : Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                // 紙本發票模式：手動開卡入口（web 無線性條碼解碼——
                // scan_policy 平台分流）。
                if (mode == ScanMode.paper)
                  Positioned(
                    left: videoRect.left,
                    right: videoRect.left,
                    top: videoRect.bottom - 48,
                    child: Center(
                      child: FilledButton.icon(
                        key: const Key('webcam-manual-entry'),
                        onPressed: _addBlankDraft,
                        icon: const Icon(Icons.receipt_long),
                        label: const Text('手動開一筆'),
                      ),
                    ),
                  ),
                // 畫面提示（只掃到明細碼等——與 APP 同款）。
                if (_hint != null)
                  Positioned(
                    left: videoRect.left,
                    right: videoRect.left,
                    top: videoRect.bottom - 12,
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
                // 診斷面板（videoRect 左下）。
                Positioned(
                  left: videoRect.left + 12,
                  top: videoRect.bottom - 40,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      '[$kWebScanAppVersion] 幀 $_frames · $_frameInfo · 命中 $_decodeHits · 解 $_decodeMs ms'
                      '${_controller.elementInfo.isEmpty ? '' : ' · ${_controller.elementInfo}'}'
                      '${_controller.diagInfo.isEmpty ? '' : ' · ${_controller.diagInfo}'}',
                      key: const Key('webcam-diag'),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ]);
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('已掃 $count 張',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            const Text('連續掃描', style: TextStyle(fontSize: 13)),
            Switch(
              key: const Key('scan-continuous-toggle'),
              value: ref.watch(continuousScanProvider),
              onChanged: (v) =>
                  ref.read(continuousScanProvider.notifier).set(v),
            ),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              TextButton(
                key: const Key('webcam-fallback-file'),
                onPressed: _fallbackToFile,
                child: const Text('改用檔案匯入'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('webcam-done'),
                onPressed: drafts.isEmpty ? null : _finish,
                icon: const Icon(Icons.done_all),
                label: const Text('完成掃描'),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  /// 在 [container] 內以 [aspect] 置中取最大內接矩形（contain 幾何）。
  Rect _containRect(Size container, double aspect) {
    final targetH = container.width / aspect;
    if (targetH <= container.height) {
      return Rect.fromLTWH(
          0, (container.height - targetH) / 2, container.width, targetH);
    }
    final targetW = container.height * aspect;
    return Rect.fromLTWH(
        (container.width - targetW) / 2, 0, targetW, container.height);
  }

  /// 引導框 rect（videoRect 內：88%×42% 置中偏上——雙 QR 橫排）。
  Rect _aimFrameRect(Rect videoRect) => Rect.fromCenter(
        center: Offset(videoRect.center.dx,
            videoRect.top + videoRect.height * 0.42),
        width: videoRect.width * 0.88,
        height: videoRect.height * 0.42,
      );

  Widget _buildFailed(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.no_photography_outlined, size: 56),
            const SizedBox(height: 12),
            const Text('相機無法使用',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_error ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('webcam-retry'),
              onPressed: () {
                _controller.dispose(); // 停止舊串流——重新請求（權限被拒後可再試）
                _start();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重試'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('webcam-fallback-file'),
              onPressed: _fallbackToFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('改用檔案匯入'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _CamState { starting, live, failed }

class _CornerBrackets extends CustomPainter {
  _CornerBrackets({required this.rect});

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    const len = 26.0;
    const r = 6.0;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(rect.left, rect.top + len)
      ..lineTo(rect.left, rect.top + r)
      ..quadraticBezierTo(rect.left, rect.top, rect.left + r, rect.top)
      ..lineTo(rect.left + len, rect.top)
      ..moveTo(rect.right - len, rect.top)
      ..lineTo(rect.right - r, rect.top)
      ..quadraticBezierTo(rect.right, rect.top, rect.right, rect.top + r)
      ..lineTo(rect.right, rect.top + len)
      ..moveTo(rect.right, rect.bottom - len)
      ..lineTo(rect.right, rect.bottom - r)
      ..quadraticBezierTo(rect.right, rect.bottom, rect.right - r, rect.bottom)
      ..lineTo(rect.right - len, rect.bottom)
      ..moveTo(rect.left + len, rect.bottom)
      ..lineTo(rect.left + r, rect.bottom)
      ..quadraticBezierTo(rect.left, rect.bottom, rect.left, rect.bottom - r)
      ..lineTo(rect.left, rect.bottom - len);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerBrackets old) => old.rect != rect;
}

/// 原生偵測器命中的條碼框（正規化 rect → videoRect 映射——綠框）。
class _NativeBoxPainter extends CustomPainter {
  _NativeBoxPainter({required this.boxes, required this.videoRect});

  final List<Rect> boxes;
  final Rect videoRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (videoRect.isEmpty || boxes.isEmpty) return;
    final fill = Paint()..color = Colors.green.withValues(alpha: 0.15);
    final stroke = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round;
    for (final box in boxes) {
      final r = Rect.fromLTRB(
          videoRect.left + box.left * videoRect.width,
          videoRect.top + box.top * videoRect.height,
          videoRect.left + box.right * videoRect.width,
          videoRect.top + box.bottom * videoRect.height);
      canvas.drawRect(r.inflate(4), fill);
      canvas.drawRect(r.inflate(4), stroke);
    }
  }

  @override
  bool shouldRepaint(_NativeBoxPainter old) =>
      old.boxes != boxes || old.videoRect != videoRect;
}
