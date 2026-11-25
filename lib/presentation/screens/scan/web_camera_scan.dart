import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import '../../../domain/entities/invoice_line_item.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../../platform/scan/camera_stream.dart';
import '../../../platform/scan/image_qr_scan.dart';
import '../../../platform/scan/tw_ein_parse.dart';
import 'import_page.dart';
import 'review_page.dart';
import 'scan_box_mapper.dart';

/// TwEin 解析器 provider（測試可覆寫 fake；VM 測試＝stub 恆 null）。
final twEinParserProvider = Provider<TwEinParser>((ref) => twEinParser);

/// 解碼函式 provider（測試可覆寫；預設＝**相機幀分層解碼**——輕量 3 區 →
/// 中央變焦 → 四象限，回傳草稿＋**解出的原始文字**（去重 key 用））。
final webCameraDecodeProvider = Provider<
        ({TransactionDraft? draft, List<String> texts})? Function(Uint8List)>(
    (ref) => (bytes) => ImageQrScanner().draftFromCameraFrame(bytes));

/// RGBA 直入解碼函式 provider（測試可覆寫；T89——**跳過 JPEG 編解碼鏈**
/// ＋900ms 時間預算＝行動裝置主執行緒卡頓上限（**只管深度升級區**——
/// 核心 3 區整張＋切半不受限＝辨識底線；預算只「提早帶成果收工」，
/// 不丟已解出的文字），超時下一 tick 續掃）。
final webCameraDecodeRgbaProvider = Provider<
        ({TransactionDraft? draft, List<String> texts})? Function(
            AnalysisFrame)>((ref) => (af) =>
    ImageQrScanner().draftFromCameraFrameRgba(af.rgba, af.width, af.height,
        budget: const Duration(milliseconds: 900)));

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

  /// **跨 tick 累積窗**（PM 2026-11-23：無法一次掃兩碼 → 各別辨識＋合併——
  /// 左碼/右碼分 tick 解出，3 秒窗內合併成完整明細；與 APP 累積窗同款）。
  final Map<String, DateTime> _recentTexts = {};

  /// 已入單的**左碼**（發票身分）——同一張不重複加入；資料對應不起來
  /// ＝另一張發票（不同左碼）。
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

  // **T90 自適應掃描頻率**（PM 2026-11-25「辨識速度有辦法每秒 5–10 幀？」）：
  // 上一 tick 耗時 ≤80ms（原生偵測快）→ **100ms＝最多 10 次/秒**；
  // 81–120ms → 200ms＝5 次/秒；
  // 解碼重（紅米 RGBA 後備深掃）→ 退 1000ms 保護主執行緒（要再快需
  // 解碼出主執行緒＝Web Worker／zxing-wasm，另案）。
  int _lastTickMs = 0;

  /// 掃描迴圈（自排程——依上一 tick 耗時調整間隔）。
  void _startScanLoop() {
    _loop?.cancel();
    _loop = Timer(_loopDelay(), () async {
      await _tryDecode();
      if (!mounted) return;
      _startScanLoop();
    });
  }

  Duration _loopDelay() {
    if (ref.read(scanPausedProvider)) {
      return const Duration(milliseconds: 400); // 確認清單開啟中——慢輪詢
    }
    if (_lastTickMs <= 80) {
      return const Duration(milliseconds: 100); // 最多 10 fps（原生偵測快路徑）
    }
    if (_lastTickMs <= 120) {
      return const Duration(milliseconds: 200); // 5 fps
    }
    return const Duration(milliseconds: 1000); // 後備解碼重——保護主執行緒
  }

  // **T88 偵測框**（PM 2026-11-25「掃到條碼要有框」）：最新 tick 的偵測框
  // （video 像素座標）＋video 原生尺寸（object-fit:cover 映射用）；
  // 無偵測＝清空（框消失＝引導繼續對準）。
  List<Rect> _codeBoxes = const [];
  Size _codeVideoSize = Size.zero;

  // **T89**：預覽 platform view 重建世代（確認清單返回時 +1——
  // 行動版瀏覽器 slot 未重新佈局的修復，見 _openReview）。
  int _previewEpoch = 0;

  /// video 原生尺寸（resolutionInfo 'WxH' → Size；無畫面＝Size.zero）。
  Size _parseVideoSize() {
    final parts = _controller.resolutionInfo.split('x');
    if (parts.length != 2) return Size.zero;
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    return (w == null || h == null) ? Size.zero : Size(w, h);
  }

  /// 每次命中後的掃描暫停（PM 2026-11-22：每掃到一張暫停 0.3 秒）＋
  /// 確認清單開啟中全停（[scanPausedProvider]）——與 APP 同款節流。
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _decodeMs = 0; // 最近一次解碼耗時（面板顯示——行動裝置效能定位）
  bool _diagExpanded = false; // 診斷行展開（PM：預設短格式）
  bool _torchOn = false; // 補光開關狀態
  bool _torchSupported = false; // 補光能力（web：track capabilities 有 torch）

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
      setState(() {
        _preview = preview;
        _state = _CamState.live;
        _torchSupported = _controller.torchSupported;
      });
      _lastTickMs = 0;
      _startScanLoop();
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

  /// 補光（手電筒）開關：web MediaStreamTrack.applyConstraints torch，
  /// 無能力或相機未啟動 → 靜默失敗。
  Future<void> _toggleTorch() async {
    await _controller.toggleTorch().catchError((Object _) {});
    if (mounted) {
      setState(() => _torchOn = _controller.torchOn);
    }
  }

  /// **解析主路徑＝TwEin**（@hsuan741220/tw-einvoice-qr 官方規格 v1.9：
  /// 77 碼欄位/品目/Base64/境外電商；右碼可缺——省略參數契約）；
  /// **後備＝既有解析器** [ImageQrScanner.draftFromQrTexts]（TwEin 組不出
  /// 時接手——缺左碼／舊式格式等）。回 null＝兩層都組不出（呼叫端引導）。
  TransactionDraft? _draftFromTexts(List<String> texts) {
    final inv = ref.read(twEinParserProvider).parseInvoice(texts);
    if (inv != null) return _twEinToDraft(inv);
    return ImageQrScanner.draftFromQrTexts(texts);
  }

  /// TwEin 解析結果 → 確認清單草稿（**金額單位＝台幣元**——TWD
  /// zero-decimal，TwEin 的 totalAmount/item unitPrice 即元，勿 ×100）。
  TransactionDraft _twEinToDraft(TwEinInvoice inv) => TransactionDraft(
        merchant: const DraftField.none(), // QR 規格無賣方名稱欄。
        totalMinor: DraftField(inv.totalAmountMinor, 1.0),
        date: inv.date != null
            ? DraftField(inv.date!, 1.0)
            : const DraftField.none(),
        sellerTaxId: inv.sellerTaxId,
        invoiceNo: inv.invoiceNumber,
        lineItems: [
          for (final it in inv.items)
            InvoiceLineItem(
              name: it.name,
              quantity: it.quantity.round(),
              unitPrice: it.unitPrice.round(),
              amount: (it.quantity * it.unitPrice).round(),
            ),
        ],
      );

  Future<void> _tryDecode() async {
    if (_state != _CamState.live || _decoding) return;
    if (ref.read(scanPausedProvider) ||
        DateTime.now().isBefore(_pausedUntil)) {
      return;
    }
    _decoding = true;
    // **T86 卡死修復**（PM 2026-11-25「感覺有功能卡住了」）：擷幀/解碼若
    // 擲例外，原寫法 `_decoding` 永遠 true → 掃描迴圈死鎖（之後什麼都
    // 掃不到，直到離開重進掃描頁）。finally 保證解鎖——例外只損失該 tick。
    try {
      await _tryDecodeTick();
    } finally {
      _decoding = false;
      // 包含取幀、辨識與入單的總耗時；慢的同步後備解碼會自動降頻。
      _lastTickMs = _decodeMs;
    }
  }

  /// zxing2 分層解碼（例外→null——異常幀只損失本 tick，不鎖死迴圈；T86）。
  ({TransactionDraft? draft, List<String> texts})? _decodeFrame(
      Uint8List bytes) {
    try {
      return ref.read(webCameraDecodeProvider)(bytes);
    } catch (_) {
      return null;
    }
  }

  /// RGBA 直入解碼（例外→null——同 JPEG 路徑防護；T89）。
  ({TransactionDraft? draft, List<String> texts})? _decodeRgbaFrame(
      AnalysisFrame af) {
    try {
      return ref.read(webCameraDecodeRgbaProvider)(af);
    } catch (_) {
      return null;
    }
  }

  /// 單次 tick 偵測（雙引擎→累積窗→解析→入單）。
  Future<void> _tryDecodeTick() async {
    final sw = Stopwatch()..start();
    TransactionDraft? draft;
    // **雙引擎——原生優先、命中即免後備**（T86 併聯 → T89 改條件式，
    // PM 2026-11-25 紅米「很卡」）：
    // ①原生 BarcodeDetector（T10；Android Chrome 存在但底層不作用＝
    //   永遠回空陣列）——**命中時直接用文字**，zxing2 截幀＋解碼整段免跑
    //   （主執行緒重活；iPhone／新 Android 每 tick 只剩原生偵測＝零卡頓）。
    // ②原生沒中／不支援 → **RGBA 直入解碼**（T89——getImageData 像素直接
    //   建圖，完全跳過 JPEG 編碼＋解碼鏈；400ms 時間預算＝卡頓上限，超時
    //   下一 tick 續掃）。紅米（偵測器死）每 tick 主執行緒省約 250–600ms。
    final native = <String>[];
    var boxes = const <Rect>[];
    if (_controller.hasNativeBarcodeDetector) {
      final codes = await _controller.detectNativeBarcodes();
      native.addAll(codes.map((c) => c.text).where((t) => t.isNotEmpty));
      // **T88 偵測框**（video 像素座標——繪製時做 cover 映射）。
      boxes = [
        for (final c in codes)
          if (c.box != null) c.box!,
      ];
    }
    var engine = '無';
    if (native.isNotEmpty) engine = '原生';
    var texts = native;
    var frameOk = native.isNotEmpty; // 原生命中＝有畫面（幀不必截）
    if (native.isEmpty) {
      final af = await _controller.captureAnalysisFrame();
      var result = af == null ? null : _decodeRgbaFrame(af);
      if (af != null) {
        frameOk = true;
      } else {
        // native/stub 平台（或 fake controller）——舊 JPEG 路徑。
        final bytes = await _controller.captureFrame();
        if (bytes != null) frameOk = true;
        result = bytes == null ? null : _decodeFrame(bytes);
      }
      final zx = result?.texts ?? const <String>[];
      if (zx.isNotEmpty) {
        engine = '後備';
        texts = zx;
      }
      draft = result?.draft;
    }
    if (mounted) {
      setState(() {
        _frames++;
        _codeBoxes = boxes;
        _codeVideoSize = _parseVideoSize();
        _frameInfo = !frameOk
            ? '無畫面'
            : '${_controller.resolutionInfo} · 引擎 $engine';
      });
    }
    sw.stop();
    if (mounted) setState(() => _decodeMs = sw.elapsedMilliseconds);
    // **跨 tick 累積窗**（3 秒）——無法一次掃兩碼 → 各別辨識＋合併
    // （PM 2026-11-23 提案：已掃過的等另一碼；對應不起來＝另一張）。
    if (texts.isNotEmpty) {
      final now2 = DateTime.now();
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
    // 累積優先：右碼補齊後合併成完整明細。
    final merged = _draftFromTexts(accumulated) ?? draft;
    if (merged == null) {
      // 只有右碼（明細碼）——引導對準左側（與 APP 同款提示）。
      if (accumulated.any((t) => t.startsWith('**'))) {
        _flashHint('✓ 偵測到右側明細碼——請再對準左側 QR（發票號那格）');
      }
      return;
    }
    if (mounted) setState(() => _decodeHits++);
    // 左碼＝發票身分：已入單的發票不重複加入（對應不起來＝另一張）。
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
    // **T89**：照片只在入單時擷一次 JPEG（舊版每 tick 擷幀＋同步編碼）。
    final photoBytes = await _controller.captureFrame();
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
    // **T89 尺寸修復**（PM 2026-11-25「確認清單返回後預覽變小」）：
    // 確認清單蓋住掃描頁時 platform view slot 被卸載；**行動版瀏覽器**
    // 返回後未重新佈局 slot（桌面 E2E 實測正常、手機異常——預覽縮小）。
    // 換 epoch key → HtmlElementView 重建 → 註冊工廠重新掛載 video →
    // slot 重新量測＝恢復貼滿。CSS 另由看門狗每秒重斷言（雙保險）。
    setState(() => _previewEpoch++);
    // **T89c**（PM：iPhone 返回後預覽又變小——Android/桌面 epoch＋resume
    // 已好）：iOS WebKit 對重掛的 video/slot 殘留狀態 → **完全重建**
    // （新元素＋新串流＋新 slot）；其他平台 → 輕量 resume（重綁＋play）。
    final fresh = await _controller.restartPreviewFresh();
    if (!mounted) return;
    if (fresh != null) {
      setState(() => _preview = fresh);
    } else {
      // **T89b**（PM：重建後「鏡頭消失，要切換鏡頭才會顯示」）——行動版
      // 重掛 video 中斷播放管線：重綁串流＋補 play（不重新談判相機）。
      await _controller.resumePreview();
    }
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
    _lastTickMs = 0;
    _startScanLoop(); // 恢復後立即沿用自適應頻率
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 回合重置（暫存清空＝新回合）→ seen 清空（可再掃同一張）；
    // 連續掃描關閉（預設）：掃到第一張 → 自動進確認清單（掃描暫停）。
    ref.listen(scanDraftsProvider, (prev, next) {
      if (next.isEmpty &&
          (_seenCodes.isNotEmpty ||
              _committedLeftCodes.isNotEmpty ||
              _recentTexts.isNotEmpty)) {
        _seenCodes.clear();
        _committedLeftCodes.clear();
        _recentTexts.clear();
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
        // 掃描模式（PM 2026-11-22：與 APP 同款按鈕方式——**置頂**，
        // 不在下方）：電子發票＝QR；紙本發票＝相機續掃＋「手動開一筆」。
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
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              KeyedSubtree(
                  key: const Key('webcam-preview'),
                  child: KeyedSubtree(
                      key: ValueKey<int>(_previewEpoch), child: _preview!)),
              // **T88 偵測框**（PM：掃到條碼顯示框）——video 像素座標經
              // object-fit:cover 映射後繪製（與 camera_stream_web 的 video
              // CSS 同步：100%×100%＋cover）；左右雙 QR 各一框。
              if (_codeBoxes.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const Key('code-boxes-paint'),
                      painter: _CodeBoxesPainter(
                        boxes: _codeBoxes,
                        videoSize: _codeVideoSize,
                      ),
                    ),
                  ),
                ),
              if (drafts.isNotEmpty)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Chip(
                    avatar: const Icon(Icons.check_circle,
                        color: Colors.green, size: 18),
                    label: Text('已加入 ${drafts.length} 張'),
                  ),
                ),
              // 切換鏡頭（PM 2026-11-21 按鈕需求）。
              Positioned(
                right: 12,
                top: 12,
                child: IconButton(
                  key: const Key('webcam-switch-camera'),
                  tooltip: '切換鏡頭',
                  onPressed: () => _controller.switchCamera(),
                  icon: const Icon(Icons.cameraswitch),
                  color: Colors.white,
                ),
              ),
              // 補光開關（web：MediaStreamTrack.applyConstraints torch；
              // 支援度有限——無能力則隱藏）。
              if (_torchSupported)
                Positioned(
                  right: 72,
                  top: 12,
                  child: GestureDetector(
                    key: const Key('webcam-torch-toggle'),
                    onTap: () => unawaited(_toggleTorch()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: _torchOn
                            ? Colors.white
                            : Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _torchOn ? Icons.flash_on : Icons.flash_off,
                        color: _torchOn ? Colors.black : Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              // 畫面提示（只掃到明細碼等——與 APP 同款）。
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
              // 紙本發票模式：手動開卡入口（web 無線性條碼解碼——
              // scan_policy 平台分流；金額/日期/商家/發票號手動輸入）。
              if (mode == ScanMode.paper)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 48,
                  child: Center(
                    child: FilledButton.icon(
                      key: const Key('webcam-manual-entry'),
                      onPressed: _addBlankDraft,
                      icon: const Icon(Icons.receipt_long),
                      label: const Text('手動開一筆'),
                    ),
                  ),
                ),
              // 診斷面板（定位「無法正確掃描」：取幀是否流動／解碼是否命中）。
              Positioned(
                left: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6)),
                  child: GestureDetector(
                    onTap: () =>
                        setState(() => _diagExpanded = !_diagExpanded),
                    child: Text(
                      _diagExpanded
                          ? '[$kWebScanAppVersion] 幀 $_frames · $_frameInfo · '
                              '命中 $_decodeHits · 解 $_decodeMs ms'
                              '${_controller.diagInfo.isEmpty ? '' : ' · ${_controller.diagInfo}'}'
                          : '幀 $_frames · 命中 $_decodeHits · 解 $_decodeMs ms',
                      key: const Key('webcam-diag'),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
            ],
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

/// **T88 偵測框繪製**（PM 2026-11-25「掃到條碼要有框」）：video 像素座標 →
/// 預覽顯示座標（object-fit: cover：等比放大至填滿→置中→超出裁切）——
/// 與 camera_stream_web 的 video CSS（100%×100%＋cover）同步。
/// 註：前鏡頭鏡像時框未做鏡像映射（掃描主流＝後鏡頭）。
class _CodeBoxesPainter extends CustomPainter {
  _CodeBoxesPainter({required this.boxes, required this.videoSize});

  final List<Rect> boxes;
  final Size videoSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (videoSize.isEmpty || boxes.isEmpty) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF00BFA5);
    final fill = Paint()..color = const Color(0x2600BFA5);
    for (final b in boxes) {
      final r = mapVideoRectToDisplay(b, videoSize, size).inflate(6);
      final rrect = RRect.fromRectAndRadius(r, const Radius.circular(8));
      canvas.drawRRect(rrect, fill);
      canvas.drawRRect(rrect, stroke);
    }
  }

  @override
  bool shouldRepaint(_CodeBoxesPainter oldDelegate) {
    if (oldDelegate.videoSize != videoSize ||
        oldDelegate.boxes.length != boxes.length) {
      return true;
    }
    for (var i = 0; i < boxes.length; i++) {
      if (oldDelegate.boxes[i] != boxes[i]) return true;
    }
    return false;
  }
}
