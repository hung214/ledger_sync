import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import '../../../domain/entities/invoice_line_item.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../../platform/scan/camera_stream.dart';
import '../../../platform/scan/image_qr_scan.dart';
import '../../../platform/scan/invoice_text_codec.dart';
import '../../../platform/scan/scan_haptics.dart';
import '../../../platform/scan/tw_ein_parse.dart';
import 'import_page.dart';
import 'review_page.dart';
import 'scan_box_mapper.dart';

/// TwEin 解析器 provider（測試可覆寫 fake；VM 測試＝stub 恆 null）。
final twEinParserProvider = Provider<TwEinParser>((ref) => twEinParser);

/// 解碼函式 provider（測試可覆寫；預設＝**相機幀分層解碼**——輕量 3 區 →
/// 中央變焦 → 四象限，回傳草稿＋**解出的原始文字**（去重 key 用））。
final webCameraDecodeProvider =
    Provider<
      ({TransactionDraft? draft, List<String> texts})? Function(Uint8List)
    >(
      (ref) =>
          (bytes) => ImageQrScanner().draftFromCameraFrame(bytes),
    );

/// RGBA 直入解碼函式 provider（測試可覆寫；T89——**跳過 JPEG 編解碼鏈**
/// ＋900ms 時間預算＝行動裝置主執行緒卡頓上限（**只管深度升級區**——
/// 核心 3 區整張＋切半不受限＝辨識底線；預算只「提早帶成果收工」，
/// 不丟已解出的文字），超時下一 tick 續掃）。
final webCameraDecodeRgbaProvider =
    Provider<
      ({TransactionDraft? draft, List<String> texts})? Function(AnalysisFrame)
    >(
      (ref) =>
          (af) => ImageQrScanner().draftFromCameraFrameRgba(
            af.rgba,
            af.width,
            af.height,
            budget: const Duration(milliseconds: 900),
          ),
    );

/// **T91 ROI 子區解碼函式 provider**（hold 階段右側限區找明細碼——
/// 測試可覆寫）。
final webCameraDecodeRegionProvider =
    Provider<List<String> Function(AnalysisFrame)>(
      (ref) =>
          (af) => ImageQrScanner.decodeRegionRgba(af.rgba, af.width, af.height),
    );

/// **T91 時間窗長度 provider**（左碼鎖定後等右碼的**逾時上限**——找到
/// 右碼的瞬間即合併入單，窗期不影響成功掃描的速度；PM 決策 3 秒 → 1 秒
/// → **2 秒**（2026-11-28 三修：1 秒窗讓 ROI 嘗試不足＝左碼逾時先入、
/// 明細短缺——他牌 App 無此上限皆可完整掃描）；測試可縮短——逾時＝左碼
/// 先入單）。
final scanHoldWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

/// 相機控制器 provider（測試可覆寫 fake）。
final webCameraControllerProvider = Provider<CameraStreamController>(
  (ref) => createCameraController(),
);

/// 部署版本（dart-define 帶入；掃描診斷面板顯示——確認更新已生效）。
const String kWebScanAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

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
  late final CameraStreamController _controller = ref.read(
    webCameraControllerProvider,
  );
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

  // **T91 順序掃描狀態機**（PM 2026-11-27「先掃左邊再掃右邊」＋「掃到
  // 一定秒數內要掃到另一碼」）：FULL＝現行全幅掃描；只掃到左碼 →
  // 進入 AWAITING（**T93 雙鎖定狀態機**——PM 2026-11-28：隨機先掃一個、
  // 各自鎖定，格式判定左/右，無空間假設）：任一碼鎖定後等另一碼；
  // 左碼先鎖＝窗期逾時左碼先入（明細可補）；右碼先鎖＝無時限等左碼。
  _ScanPhase _phase = _ScanPhase.full;

  /// 鎖定的左碼（發票身分——等待期間持續留窗，防止窗期先過期）。
  String? _lockedLeftText;

  /// 鎖定左碼的偵測框（video 像素座標；原生路徑有——綠色 ✓ 持續顯示）。
  Rect? _lockedLeftBox;

  /// **T93**：鎖定的右碼（明細——`**` 起始；可先於左碼鎖定）。
  String? _lockedRightText;

  /// 等待另一碼的時限到期時刻（左碼先鎖＋[scanHoldWindowProvider]；
  /// **右碼先鎖＝null 無時限**——等使用者掃左碼）。
  DateTime? _holdDeadline;

  /// 偵測框留住時間戳（T91 防閃爍——無偵測 tick 保留上批框 600ms）。
  DateTime _codeBoxesAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 安全掃計數（hold 階段：後備路徑每 3 tick 全幅掃一次；原生路徑
  /// 升級 ROI 後每 2 tick 交替全幅——防發票移動漏掃）。
  int _sweepCounter = 0;

  /// 預覽顯示區尺寸（LayoutBuilder 捕捉——ROI 幾何計算用）。
  Size _previewDisplaySize = Size.zero;

  /// hold 倒數 UI 計時器（250ms 重繪——與解碼 tick 頻率脫鉤）。
  Timer? _holdTicker;

  /// **T93 掃描框帶**（video 像素座標）——取景框**整條橫帶**＋垂直 20%
  /// padding，反映射＋夾限。解碼只吃框內區域（效率：帶 ≈ 全幅 25%——
  /// PM 2026-11-28「掃描完成的圖片不該是完整一張照片」）。
  /// 無顯示尺寸／video 尺寸 → null（全幅後備）。
  Rect? _guideBandVideoRect() {
    final display = _previewDisplaySize;
    final video = _parseVideoSize();
    if (display.isEmpty || video.isEmpty) return null;
    final guide = Rect.fromCenter(
      center: Offset(display.width / 2, display.height / 2),
      width: display.width * 0.88,
      height: display.height * 0.27,
    );
    // padding：QR 常略高/低於橫帶——垂直多留 20%。
    final padded = guide.inflate(guide.height * 0.2);
    final clipped = _clipToSize(padded, display);
    if (clipped == null) return null;
    final videoRect = mapDisplayRectToVideo(clipped, video, display);
    final roi = _clipToSize(videoRect, video);
    return roi;
  }

  /// 矩形夾限至 [bounds]（交矩形；不相交 → null）。
  static Rect? _clipToSize(Rect r, Size bounds) {
    final left = r.left.clamp(0.0, bounds.width);
    final top = r.top.clamp(0.0, bounds.height);
    final right = r.right.clamp(0.0, bounds.width);
    final bottom = r.bottom.clamp(0.0, bounds.height);
    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// 進入 hold（左碼鎖定＋時間窗啟動＋倒數 UI）。
  void _enterHold(String leftText, {Rect? box}) {
    _phase = _ScanPhase.awaitingRight;
    _lockedLeftText = leftText;
    _lockedLeftBox = box;
    // 左碼先鎖＝有時限（窗期逾時→左碼先入）；右碼先鎖＝無時限。
    _holdDeadline = DateTime.now().add(ref.read(scanHoldWindowProvider));
    _startHoldTicker();
  }

  /// 倒數/提示重繪 tick（與解碼 tick 頻率脫鉤）。
  void _startHoldTicker() {
    _holdTicker?.cancel();
    _holdTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _phase != _ScanPhase.awaitingRight) return;
      setState(() {});
    });
  }

  /// 重置狀態機回 FULL（入單後／逾時後／換發票）。
  void _resetScanPhase({bool clearWindow = false}) {
    _phase = _ScanPhase.full;
    _lockedLeftText = null;
    _lockedLeftBox = null;
    _holdDeadline = null;
    _holdTicker?.cancel();
    _holdTicker = null;
    if (clearWindow) _recentTexts.clear();
  }

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

  /// **T92 除錯簽章**（PM 2026-11-28「要知道掃描成功是哪種方式」）：
  /// [_tickSig]＝本 tick 解碼方式（引擎×路徑）；[_lastSuccessInfo]＝最後
  /// 一次成功入單的簽章（引擎×路徑×階段）——診斷行**持久顯示**，留到
  /// 下一次成功才覆蓋。
  String _tickSig = '';
  String _lastSuccessInfo = '';

  /// **T93 還原遙測**（PM 2026-11-28 亂碼診斷）：可疑文字數／成功還原數
  /// ＋最後一個可疑文字的前 8 字（診斷行顯示——裝置端地面真相）。
  int _suspectCount = 0;
  int _recoveredCount = 0;
  String _lastSuspectPreview = '';
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
    if (ref.read(scanPausedProvider) || DateTime.now().isBefore(_pausedUntil)) {
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
    Uint8List bytes,
  ) {
    try {
      return ref.read(webCameraDecodeProvider)(bytes);
    } catch (_) {
      return null;
    }
  }

  /// RGBA 直入解碼（例外→null——同 JPEG 路徑防護；T89）。
  ({TransactionDraft? draft, List<String> texts})? _decodeRgbaFrame(
    AnalysisFrame af,
  ) {
    try {
      return ref.read(webCameraDecodeRgbaProvider)(af);
    } catch (_) {
      return null;
    }
  }

  /// 單次 tick 偵測（雙引擎→**T93 雙鎖定狀態機**→累積窗→解析→入單）。
  Future<void> _tryDecodeTick() async {
    final sw = Stopwatch()..start();
    TransactionDraft? decodedDraft; // 解碼器直接回傳的草稿（舊格式後備）
    final now = DateTime.now();
    final inAwait = _phase == _ScanPhase.awaitingRight;
    _sweepCounter++;
    // **T93 解碼區域＝掃描框帶**（PM 2026-11-28「掃描完成的圖片不該是
    // 完整一張照片」——帶 ≈ 全幅 25%＝效率 4 倍）；每 3 tick **全幅安全
    // 掃**（防發票構圖出框/移動漏掃）。
    final sweep = _sweepCounter % 3 == 2;
    final band = inAwait ? _guideBandVideoRect() : null;
    final region = (sweep || band == null) ? null : band;
    // **雙引擎——原生優先、命中即免後備**（T86 併聯 → T89 改條件式，
    // PM 2026-11-25 紅米「很卡」）：
    // ①原生 BarcodeDetector（T10；Android Chrome 存在但底層不作用＝
    //   永遠回空陣列）——**命中時直接用文字**，zxing2 截幀＋解碼整段免跑
    //   （主執行緒重活；iPhone／新 Android 每 tick 只剩原生偵測＝零卡頓）。
    // ②原生沒中／不支援 → **RGBA 直入解碼**（T89——getImageData 像素直接
    //   建圖，完全跳過 JPEG 編碼＋解碼鏈；400ms 時間預算＝卡頓上限，超時
    //   下一 tick 續掃）。**T93**：解碼區域＝掃描框帶（sweep tick 全幅）。
    final native = <String>[];
    final detected = <DetectedCode>[];
    if (_controller.hasNativeBarcodeDetector) {
      final codes = await _controller.detectNativeBarcodes(region: region);
      detected.addAll(codes);
      for (final c in codes) {
        if (c.text.isEmpty) continue;
        // **T93 繁中亂碼修復**：原生偵測器（Apple）不回原始位元組——可疑
        // 文字（Big5/UTF-8 誤解）以**該碼偵測框區域重跑 zxing2**（960
        // 放大＋rawBytes 還原鏈）——還原成功才取代，否則原樣。
        final box = c.box;
        if (isSuspectMojibake(c.text)) {
          _suspectCount++;
          _lastSuspectPreview = c.text.length > 8
              ? c.text.substring(0, 8)
              : c.text;
        }
        if (isSuspectMojibake(c.text) && box != null) {
          // 外擴 25%（靜區——QR 解碼需要白邊；緊貼框＝zxing2 解不出）。
          final paddedBox = box
              .inflate(box.shortestSide * 0.25)
              .shift(Offset(-box.shortestSide * 0.05, 0));
          final af = await _controller.captureAnalysisFrame(region: paddedBox);
          final zx = af == null ? null : _decodeRgbaFrame(af);
          var recovered = false;
          for (final t in zx?.texts ?? const <String>[]) {
            if (!isSuspectMojibake(t)) {
              native.add(t);
              recovered = true;
              _recoveredCount++;
              break;
            }
          }
          if (!recovered) native.add(c.text);
        } else {
          native.add(c.text);
        }
      }
    }
    // **T88 偵測框**（video 像素座標——繪製時做 cover 映射）。
    final boxes = [
      for (final c in detected)
        if (c.box != null) c.box!,
    ];
    var engine = '無';
    if (native.isNotEmpty) engine = '原生';
    var texts = native;
    var frameOk = native.isNotEmpty; // 原生命中＝有畫面（幀不必截）
    if (native.isEmpty) {
      // **T93**：RGBA 直入解碼——區域＝掃描框帶（sweep tick 全幅安全掃）。
      final af = await _controller.captureAnalysisFrame(region: region);
      var result = af == null ? null : _decodeRgbaFrame(af);
      if (af != null) {
        frameOk = true;
      } else {
        // native/stub 平台（或 fake controller）——舊 JPEG 路徑。
        final bytes = await _controller.captureFrame();
        if (bytes != null) frameOk = true;
        result = bytes == null ? null : _decodeFrame(bytes);
      }
      decodedDraft = result?.draft;
      final zx = result?.texts ?? const <String>[];
      if (zx.isNotEmpty) {
        engine = '後備';
        texts = zx;
      }
    }
    // **T92 除錯簽章**：本 tick 的解碼方式（引擎×區域）——入單時寫入簽章。
    _tickSig = '$engine·${region != null ? '掃描框' : '全幅'}';
    if (mounted) {
      setState(() {
        _frames++;
        // **T91 防閃爍**：無偵測 tick 保留上批框 600ms（命中幀與未命中
        // 幀交替＝框閃爍——留住至確定消失）。
        if (boxes.isNotEmpty) {
          _codeBoxes = boxes;
          _codeBoxesAt = now;
        } else if (now.difference(_codeBoxesAt).inMilliseconds > 600) {
          _codeBoxes = const [];
        }
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
      _recentTexts.removeWhere(
        (_, t) => now2.difference(t) > const Duration(seconds: 3),
      );
      for (final t in texts) {
        // **T90f**（PM「辨識時慢時快」）：新的**左碼**＝新發票的開始——
        // 清掉先前孤兒右碼（`**`），防止跨發票混碼（舊右碼拼進新左碼）。
        if (ImageQrScanner.extractOfficialLeft(t) != null) {
          _recentTexts.removeWhere((k, _) => k.startsWith('**'));
        }
        _recentTexts[t] = now2;
      }
      // **T91→T93**：鎖定中的碼持續留窗（不刷新會先過期，另一碼到時
      // 合併不齊）。
      if (_lockedLeftText != null) {
        _recentTexts[_lockedLeftText!] = now2;
      }
      if (_lockedRightText != null) {
        _recentTexts[_lockedRightText!] = now2;
      }
    }
    final accumulated = _recentTexts.keys.toList();
    if (accumulated.isEmpty) return;
    if (mounted) setState(() => _decodeMs = sw.elapsedMilliseconds);
    // 條碼分類（T91——左碼＝發票身分、右碼＝明細）。
    final rights = accumulated.where((t) => t.startsWith('**')).toList();
    final lefts = <String>[
      for (final t in accumulated)
        if (ImageQrScanner.extractOfficialLeft(t) != null)
          ImageQrScanner.extractOfficialLeft(t)!,
    ];

    // —— **T93 雙鎖定狀態機**（PM 2026-11-28：隨機先掃一個、各自鎖定，
    // 格式判定左/右，無空間假設；左碼＝官方 77 碼、右碼＝`**` 起始）。
    // ①鎖定：窗內任一未鎖定的碼 → 鎖定（順序不限）。
    // **防重複**：已入單的左碼不鎖定（T93 回歸修復——committed 檢查曾在
    // 舊 FULL 塊，重寫時遺漏＝同發票重複入單）。
    final uncommittedLefts = lefts
        .where((l) => !_committedLeftCodes.contains(l))
        .toList();
    if (_lockedLeftText == null && uncommittedLefts.isNotEmpty) {
      _enterHold(
        uncommittedLefts.last,
        box: _boxForText(uncommittedLefts.last, detected),
      );
    }
    if (_lockedRightText == null && rights.isNotEmpty) {
      _lockedRightText = rights.last;
      if (_lockedLeftText == null) {
        // 右碼先鎖＝**無時限**（等使用者掃左碼）。
        _holdDeadline = null;
        _startHoldTicker();
        _phase = _ScanPhase.awaitingRight;
      }
    }
    // ②換票防護：awaiting 中出現**另一張未入單**的左碼 → 舊左碼先入＋清窗。
    if (_lockedLeftText != null &&
        uncommittedLefts.any((l) => l != _lockedLeftText)) {
      await _commitLeftOnly();
      _resetScanPhase(clearWindow: true);
      for (final t in texts) {
        _recentTexts[t] = DateTime.now();
      }
      return;
    }
    // ③兩碼齊 → 合併入單（含全部明細）。
    if (_lockedLeftText != null && _lockedRightText != null) {
      final merged = _draftFromTexts([_lockedLeftText!, _lockedRightText!]);
      if (merged != null) {
        if (mounted) setState(() => _decodeHits++);
        await _commitMerged(merged, [
          _lockedLeftText!,
          _lockedRightText!,
        ], _lockedLeftText);
        _resetScanPhase();
      }
      return;
    }
    // ④逾時：左碼已鎖、右碼未到、窗期過 → 左碼先入（明細可稍後補）。
    if (_lockedLeftText != null &&
        _lockedRightText == null &&
        _holdDeadline != null &&
        now.isAfter(_holdDeadline!)) {
      await _commitLeftOnly();
      _resetScanPhase();
      return;
    }
    // ⑤僅右碼鎖定 → 無時限等待左碼（提示已顯示，使用者控制節奏）。
    if (_lockedRightText != null && _lockedLeftText == null) return;
    // 左碼已鎖、右碼未到、窗期未過 → 繼續等（④會在窗期過後處理）。
    if (_lockedLeftText != null) return;
    // —— **非官方碼直入**（T93 相容路徑：舊內部格式/內部測資——無任何
    // 鎖定且能成草稿 → 既有立即入單行為；官方碼已在①鎖定不會走到這）。
    if (accumulated.every(_seenCodes.contains)) return; // 同一張還在畫面中
    // **防重複**：已入單的發票（左碼）不再入單（T93 回歸修復）。
    final uncommittedLeft = lefts.firstWhere(
      (l) => !_committedLeftCodes.contains(l),
      orElse: () => '',
    );
    if (lefts.isNotEmpty && uncommittedLeft.isEmpty) return;
    final legacyMerged = _draftFromTexts(accumulated) ?? decodedDraft;
    if (legacyMerged == null) return;
    if (mounted) setState(() => _decodeHits++);
    await _commitMerged(legacyMerged, accumulated, null);
  }

  /// 偵測結果中找 [leftText] 所在條碼的框（video 像素座標）。
  /// extractOfficialLeft 回子字串——以「包含」比對（Vision 前導雜訊容錯）。
  static Rect? _boxForText(String leftText, List<DetectedCode> detected) {
    for (final c in detected) {
      if (c.text.contains(leftText) && c.box != null) return c.box;
    }
    return null;
  }

  /// **T91**：以鎖定左碼組左-only 草稿入單（逾時／換發票——PM 決策）。
  Future<void> _commitLeftOnly() async {
    final left = _lockedLeftText;
    if (left == null || _committedLeftCodes.contains(left)) return;
    final draft = _draftFromTexts([left]);
    if (draft == null) return;
    await _commitMerged(draft, [left], left);
    _lastSuccessInfo = '$_tickSig · 左碼逾時先入';
    _flashHint('✓ 已記發票——右側明細碼未掃到，明細可稍後補');
  }

  /// 入單（現行流程抽出共用：FULL 立即入單／hold 合併入單／左-only 入單）。
  Future<void> _commitMerged(
    TransactionDraft merged,
    List<String> codes,
    String? leftCode,
  ) async {
    // **T92 除錯簽章**：入單方式（引擎×路徑×階段——診斷行「上次成功」）。
    _lastSuccessInfo = '$_tickSig · ${leftCode == null ? '直入' : 'hold合併'}';
    // **掃描成功震動**（T92c；Android Chrome 支援，iOS Safari 靜默）。
    vibrateSuccess();
    // **T89**：照片只在入單時擷一次 JPEG（舊版每 tick 擷幀＋同步編碼）。
    final photoBytes = await _controller.captureFrame();
    ref
        .read(scanDraftsProvider.notifier)
        .add(ScannedItem(draft: merged, photoBytes: photoBytes));
    for (final t in codes) {
      _seenCodes.add(t);
      // **T90e**（PM「辨識時慢時快」）：入單即清累積窗——已入單的碼留在
      // 窗內會**擋住下一張**（舊左碼先命中 _committedLeftCodes → 整個
      // tick 跳過，要等 3 秒過期才掃得到新發票）。
      _recentTexts.remove(t);
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewPage(items: List.of(items)),
      ),
    );
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
    ref
        .read(scanDraftsProvider.notifier)
        .add(ScannedItem(draft: TransactionDraft.blank(DateTime.now())));
  }

  void _fallbackToFile() {
    _loop?.cancel();
    _controller.dispose();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const ImportPage()),
    );
  }

  @override
  void dispose() {
    _loop?.cancel();
    _hintReset?.cancel();
    _holdTicker?.cancel(); // T91 倒數計時器
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
              _recentTexts.isNotEmpty ||
              _phase != _ScanPhase.full)) {
        _seenCodes.clear();
        _committedLeftCodes.clear();
        _recentTexts.clear();
        // **T91**：新回合＝狀態機歸零（hold 中按返回退出→下次乾淨開始）。
        _resetScanPhase(clearWindow: true);
      }
      // **T90d**（PM 2026-11-26「確認清單沒按 OK 直接退出→變成連續掃描
      // 模式」）：原條件「prev 空」——按返回時草稿仍非空 → 之後每掃一張
      // 都不再自動進確認清單（行為＝連續掃描）。改為「**有新增就觸發**」
      // （單張模式＝每掃到一張都自動進確認清單；按返回未存的項目保留，
      // 下一張再掃時連同先前項目一起進確認清單）。
      if (!ref.read(continuousScanProvider) &&
          next.length > (prev?.length ?? 0)) {
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
                child: Text(
                  '已掃 $count 張',
                  key: const Key('webcam-count'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
                label: Text('電子發票 QR'),
              ),
              ButtonSegment(
                value: ScanMode.paper,
                icon: Icon(Icons.receipt_long),
                label: Text('紙本發票'),
              ),
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
                  key: ValueKey<int>(_previewEpoch),
                  child: _preview!,
                ),
              ),
              // **T93 點選對焦**（PM 2026-11-28）：tap 預覽 → 該點
              // pointsOfInterest（瀏覽器支援度不一；best-effort＋提示）。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (d) {
                    final video = _parseVideoSize();
                    if (video.isEmpty) return;
                    final n = mapDisplayPointToVideoNormalized(
                      d.localPosition,
                      video,
                      _previewDisplaySize,
                    );
                    unawaited(_controller.focusAt(n.dx, n.dy));
                    _flashHint('已對焦');
                  },
                ),
              ),
              // **T90c/T91 取景引導框**（狀態化）：FULL＝兩碼放置示意；
              // hold＝左半綠 ✓（鎖定）＋右半引導（獵右碼）＋倒數。
              // 後備路徑無偵測框座標 → 本框半邊高亮即為「掃到」的視覺提示。
              if (mode == ScanMode.eInvoice &&
                  (_codeBoxes.isEmpty || _phase == _ScanPhase.awaitingRight))
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _previewDisplaySize = constraints.biggest; // ROI 幾何用
                        return _buildGuide(constraints);
                      },
                    ),
                  ),
                ),
              // **T88 偵測框**（PM：掃到條碼顯示框）——video 像素座標經
              // object-fit:cover 映射後繪製（與 camera_stream_web 的 video
              // CSS 同步：100%×100%＋cover）；左右雙 QR 各一框。
              // **T91**：鎖定左碼另繪綠色 ✓ 框（持續顯示，不隨 tick 消失）。
              if (_codeBoxes.isNotEmpty || _lockedLeftBox != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const Key('code-boxes-paint'),
                      painter: _CodeBoxesPainter(
                        boxes: _codeBoxes,
                        videoSize: _codeVideoSize,
                        lockedBox: _lockedLeftBox,
                      ),
                    ),
                  ),
                ),
              if (drafts.isNotEmpty)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Chip(
                    avatar: const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 18,
                    ),
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
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _torchOn ? Colors.white : Colors.black54,
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
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _hint!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
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
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: GestureDetector(
                    onTap: () => setState(() => _diagExpanded = !_diagExpanded),
                    // **T92b 簽章獨立一行**（PM 2026-11-28：主行太長）。
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _diagExpanded
                              ? '[$kWebScanAppVersion] 幀 $_frames · $_frameInfo · '
                                    '命中 $_decodeHits · 解 $_decodeMs ms'
                                    '${_controller.diagInfo.isEmpty ? '' : ' · ${_controller.diagInfo}'}'
                              : '幀 $_frames · 命中 $_decodeHits · 解 $_decodeMs ms'
                                    ' · zoom ${_controller.zoomSupported ? '✓' : '✗'}'
                                    ' · 還原 $_recoveredCount/$_suspectCount'
                                    '${_lastSuspectPreview.isEmpty ? '' : '(${_lastSuspectPreview})'}',
                          key: const Key('webcam-diag'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                        if (_lastSuccessInfo.isNotEmpty)
                          Text(
                            '上次成功：$_lastSuccessInfo',
                            key: const Key('webcam-last-success'),
                            style: const TextStyle(
                              color: Colors.tealAccent,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                '已掃 $count 張',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
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
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQrGuideIcon() => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.32),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Icon(Icons.qr_code_2, color: Colors.white, size: 42),
  );

  /// **T91 狀態化取景引導框**：
  /// - FULL：label「把左右 QR 條碼放進框內」＋兩半 QR 示意（右半在窗內
  ///   已有右碼時亮 teal——「偵測到右碼」提示，與 _flashHint 同步）。
  /// - AWAITING_RIGHT：label「✓ 左碼已鎖定——對準右側明細碼（N 秒）」，
  ///   左半綠 ✓、右半持續引導（PM：不管哪個條碼掃到都要有提示——後備
  ///   路徑無偵測框座標，本框半邊狀態即提示）。
  Widget _buildGuide(BoxConstraints constraints) {
    final guideWidth = constraints.maxWidth * 0.88;
    final guideHeight = constraints.maxHeight * 0.27;
    final holding = _phase == _ScanPhase.awaitingRight;
    // **T93 雙鎖定**：右碼先鎖＝無時限提示（等左碼）。
    final rightLocked = _lockedRightText != null && _lockedLeftText == null;
    final remainMs = holding && _holdDeadline != null
        ? _holdDeadline!.difference(DateTime.now()).inMilliseconds
        : 0;
    final remainSec = remainMs <= 0 ? 0 : (remainMs / 1000).ceil();
    final rightDetected =
        !holding && _recentTexts.keys.any((t) => t.startsWith('**'));
    return Center(
      child: SizedBox(
        width: guideWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: holding
                    ? const Color(0xE600C853)
                    : Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    holding ? Icons.check_circle : Icons.center_focus_strong,
                    color: Colors.white,
                    size: 17,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    // **T93 雙鎖定**：右碼先鎖＝無時限提示；左碼先鎖＝倒數。
                    rightLocked
                        ? '✓ 已鎖定明細碼——掃描發票左碼'
                        : holding
                        ? '左碼已鎖定——對準右側明細碼（$remainSec 秒）'
                        : '把左右 QR 條碼放進框內',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: guideHeight,
              decoration: BoxDecoration(
                color: holding
                    ? const Color(0x1600C853)
                    : const Color(0x1600BFA5),
                border: Border.all(
                  color: holding
                      ? const Color(0xDD00C853)
                      : const Color(0xDD00BFA5),
                  width: 2.5,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  holding ? _buildLockedHalf() : _buildQrGuideIcon(),
                  Container(
                    width: 1,
                    height: guideHeight * 0.58,
                    color: Colors.white54,
                  ),
                  _buildHuntingHalf(holding, rightDetected),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左半：已鎖定（綠 ✓＋「已鎖定」）。
  Widget _buildLockedHalf() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0x3300C853),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFF00C853), width: 1.5),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: Colors.white, size: 30),
        SizedBox(width: 6),
        Text(
          '已鎖定',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  /// 右半：hold＝獵右碼（白 icon＋綠邊高亮）；FULL＝QR 示意
  /// （右碼已在窗內時 teal 高亮——偵測到右碼的視覺回饋）。
  Widget _buildHuntingHalf(bool holding, bool rightDetected) {
    final highlight = holding || rightDetected;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: highlight
            ? const Color(0x3300C853)
            : Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(8),
        border: highlight
            ? Border.all(color: const Color(0xFF00C853), width: 1.5)
            : null,
      ),
      child: const Icon(Icons.qr_code_2, color: Colors.white, size: 42),
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
            const Text(
              '相機無法使用',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
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

/// **T91 掃描階段**：FULL＝全幅掃描（現行）；AWAITING_RIGHT＝左碼已
/// 鎖定、時間窗內只獵右碼（右 ROI／放大偵測）。
enum _ScanPhase { full, awaitingRight }

/// **T88 偵測框繪製**（PM 2026-11-25「掃到條碼要有框」）：video 像素座標 →
/// 預覽顯示座標（object-fit: cover：等比放大至填滿→置中→超出裁切）——
/// 與 camera_stream_web 的 video CSS（100%×100%＋cover）同步。
/// **T91**：[lockedBox]（鎖定左碼）繪**綠色＋✓**且持續顯示（不隨 tick
/// 消失——時間窗期間的「已掃到」視覺提示）；其餘偵測框維持 teal。
/// 註：前鏡頭鏡像時框未做鏡像映射（掃描主流＝後鏡頭）。
class _CodeBoxesPainter extends CustomPainter {
  _CodeBoxesPainter({
    required this.boxes,
    required this.videoSize,
    this.lockedBox,
  });

  final List<Rect> boxes;
  final Size videoSize;
  final Rect? lockedBox;

  @override
  void paint(Canvas canvas, Size size) {
    if (videoSize.isEmpty) return;
    if (lockedBox != null) {
      final r = mapVideoRectToDisplay(lockedBox!, videoSize, size).inflate(6);
      _drawBox(canvas, r, const Color(0xFF00C853), const Color(0x3300C853));
      _paintCheck(canvas, r);
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF00BFA5);
    final fill = Paint()..color = const Color(0x2600BFA5);
    for (final b in boxes) {
      if (b == lockedBox) continue; // 鎖定框已繪（避免疊框）
      final r = mapVideoRectToDisplay(b, videoSize, size).inflate(6);
      final rrect = RRect.fromRectAndRadius(r, const Radius.circular(8));
      canvas.drawRRect(rrect, fill);
      canvas.drawRRect(rrect, stroke);
    }
  }

  void _drawBox(Canvas canvas, Rect r, Color strokeColor, Color fillColor) {
    final rrect = RRect.fromRectAndRadius(r, const Radius.circular(8));
    canvas.drawRRect(rrect, Paint()..color = fillColor);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..color = strokeColor,
    );
  }

  /// 鎖定框角落 ✓（綠圓＋白勾——「這碼已掃到」）。
  void _paintCheck(Canvas canvas, Rect r) {
    final c = Offset(r.left + 14, r.top + 14);
    canvas.drawCircle(c, 11, Paint()..color = const Color(0xFF00C853));
    final check = Path()
      ..moveTo(c.dx - 4.5, c.dy + 0.5)
      ..lineTo(c.dx - 1, c.dy + 4)
      ..lineTo(c.dx + 5, c.dy - 3.5);
    canvas.drawPath(
      check,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_CodeBoxesPainter oldDelegate) {
    if (oldDelegate.videoSize != videoSize ||
        oldDelegate.boxes.length != boxes.length ||
        oldDelegate.lockedBox != lockedBox) {
      return true;
    }
    for (var i = 0; i < boxes.length; i++) {
      if (oldDelegate.boxes[i] != boxes[i]) return true;
    }
    return false;
  }
}
