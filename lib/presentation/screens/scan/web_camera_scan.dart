import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/scan/scan_state.dart';
import '../../../domain/entities/invoice_line_item.dart';
import '../../../domain/entities/transaction_draft.dart';
import '../../../platform/scan/html5qrcode_scanner.dart';
import '../../../platform/scan/image_qr_scan.dart';
import 'import_page.dart';
import 'review_page.dart';

/// html5-qrcode 掃描器 provider（測試可覆寫 fake——T83）。
final html5QrScannerProvider =
    Provider<Html5QrScanner>((ref) => html5QrScanner);

/// 部署版本（dart-define 帶入；掃描診斷面板顯示——確認更新已生效）。
const String kWebScanAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// **PWA 即時相機掃描**（F14；T83 技術替換＋**T84 修復** PM 2026-11-25）。
///
/// **版面基準＝tag `pwa-0.5.2`**（PM 2026-11-25 指示「掃描頁面的版面我要
/// 以 tag pwa-0.5.2 為主」）——模式切換置頂／預覽 Stack（已加入 Chip、
/// 切換鏡頭、補光、提示 pill、手動開一筆、診斷面板）／清單列＋連續掃描／
/// 底部操作列；引擎換為 T83 html5-qrcode＋TwEin。
///
/// 流程：**html5-qrcode**（相機連續掃描——自帶取幀/解碼迴圈，跨平台含
/// iOS Safari）→ onSuccess 驅動 → **累積窗合併**（左碼/右碼/Code 39 各別
/// 解出）→ **TwEin 解析**（@hsuan741220/tw-einvoice-qr——官方規格 v1.9：
/// 77 碼欄位/品目/Base64/境外電商）→ 加入草稿（同張去重）→ 「完成掃描」
/// → 確認清單（ReviewPage）。相機不可用 → **回退檔案匯入**。
///
/// **T84 掛載修復**：reader div 以 `HtmlElementView` platform view 掛在
/// **Flutter 樹內**——T83 直接 append 到 `document.body` 使 video 渲染在
/// App 畫布之外（整頁 UI 破版）。iOS 相機管線保護（停軌毒化 → 重進整頁
/// 重載＋自動回掃描）回補，架構對齊 camera_stream_web（T65 PM 驗證版）。
///
/// 解析雙保險：TwEin 組不出（缺左碼等）→ 既有解析器
/// [ImageQrScanner.draftFromQrTexts] 接手；再不行 → 引導對準左碼。
///
/// 測試 keys：`webcam-preview`／`webcam-count`／`webcam-switch-camera`／
/// `webcam-torch-toggle`／`webcam-diag`／`webcam-done`／`webcam-fallback-file`。
class WebCameraScanPage extends ConsumerStatefulWidget {
  const WebCameraScanPage({super.key});

  @override
  ConsumerState<WebCameraScanPage> createState() => _WebCameraScanPageState();
}

class _WebCameraScanPageState extends ConsumerState<WebCameraScanPage> {
  _CamState _state = _CamState.starting;
  String? _error;
  Widget? _preview;
  late final Html5QrScanner _scanner = ref.read(html5QrScannerProvider);

  /// 掛載 div（html5-qrcode 在此 element 內建 video）。
  static const String _readerViewType = 'html5qrcode-reader';

  /// **session 級去重＝條碼原始內容**（PM 2026-11-22 修「換一張發票就
  /// 掃描不到」：不同發票＝不同字串，永不誤擋；同一張在畫面中不重複）。
  final Set<String> _seenCodes = <String>{};

  /// **跨 tick 累積窗**（PM 2026-11-23：無法一次掃兩碼 → 各別辨識＋合併——
  /// 左碼/右碼分次解出，3 秒窗內合併成完整明細；與 APP 累積窗同款）。
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

  // 診斷面板（PM 2026-11-21「無法正確掃描」定位用；pwa-0.5.2 格式）：
  String _frameInfo = '—'; // 掃描器狀態摘要（引擎＋facing）
  int _decodeHits = 0; // 解碼命中次數
  Timer? _diagTicker; // 幀數流動可觀測（1 秒刷新——pwa-0.5.2 同款節奏）

  /// 每次命中後的掃描暫停（PM 2026-11-22：每掃到一張暫停 0.3 秒）＋
  /// 確認清單開啟中全停（[scanPausedProvider]）——與 APP 同款節流。
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _diagExpanded = false; // 診斷行展開（PM：預設短格式）
  bool _torchOn = false; // 補光開關狀態
  bool _torchSupported = false; // 補光能力（html5-qrcode track torch）

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
    // JS 套件未載（資源缺失）→ 直接回退檔案匯入（不卡死）。
    if (!_scanner.jsLoaded) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.failed;
        _error = '掃描元件載入失敗（web/scan/ 資源缺失）——請使用檔案匯入';
      });
      return;
    }
    // **T84 修復**：reader div 以 platform view 掛在 Flutter 樹內
    // （HtmlElementView——工廠建立 div，html5-qrcode 在其中建 video）。
    // T83 直接 append 到 body 會讓 video 渲染在 App 畫布外＝整頁破版。
    if (kIsWeb) {
      _scanner.registerReaderView(_readerViewType); // 註冊工廠（冪等）
      _preview = const HtmlElementView(viewType: _readerViewType);
    } else {
      // VM 測試用佔位（fake onDecoded 照常驅動）
      _preview = const SizedBox(key: Key('fake-preview'));
    }
    setState(() {}); // 掛載 platform view（工廠於下一幀建立 reader div）
    // 輪詢等待 div 進入 DOM（html5-qrcode 需要 element 存在＋有尺寸）。
    for (int i = 0; i < 50; i++) {
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 100));
      final divReady = await _checkReaderDivReady();
      if (divReady) break;
    }
    if (!mounted) return;
    try {
      await _scanner.start(
        elementId: 'ls-h5q-reader',
        onDecoded: _onHtml5Decoded,
      );
      if (!mounted) return;
      setState(() {
        _state = _CamState.live;
        _torchSupported = _scanner.torchSupported;
        _frameInfo = 'html5qrcode · facing=${_scanner.facingLabel}';
      });
      // 幀數流動可觀測（1 秒刷新——pwa-0.5.2 診斷節奏）。
      _diagTicker?.cancel();
      _diagTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _state == _CamState.live) setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.failed;
        _error = '相機啟動失敗：$e';
      });
    }
  }

  /// 切換鏡頭（pwa-0.5.2 版面按鈕；iOS 走整頁重載式——頁面會重載，
  /// 本 Future 永不完成；桌面同 session 秒切）。
  Future<void> _switchCamera() async {
    try {
      await _scanner.switchCamera();
      if (!mounted) return;
      setState(() {
        _torchOn = _scanner.torchOn;
        _frameInfo = 'html5qrcode · facing=${_scanner.facingLabel}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _CamState.failed;
        _error = '切換鏡頭失敗：$e';
      });
    }
  }

  /// 檢查 reader div 是否已進入 DOM（html5-qrcode 需要 element 存在＋有尺寸）。
  Future<bool> _checkReaderDivReady() async {
    try {
      return await _scanner.checkReaderDivReady('ls-h5q-reader');
    } catch (_) {
      return false;
    }
  }

  /// **解碼入口**（T83——html5-qrcode onSuccess 驅動，取代 1.2s 取幀迴圈；
  /// T84——**等右碼**：左碼先現時不入單，等右碼進窗湊完整明細（與 APP
  /// F03 同款），窗尾 2.4 秒仍無右碼才以左碼先入單）。
  void _onHtml5Decoded(String text) {
    // 掃描節流（確認清單開啟中全停＋每筆入單後 0.3 秒暫停——與 APP 同款）。
    if (ref.read(scanPausedProvider) ||
        DateTime.now().isBefore(_pausedUntil)) {
      return;
    }
    // **跨 tick 累積窗**（3 秒——左碼/右碼/一維各別解出後合併，重用既有）。
    final now = DateTime.now();
    _recentTexts.removeWhere(
        (_, t) => now.difference(t) > const Duration(seconds: 3));
    _recentTexts[text] = now;
    final accumulated = _recentTexts.keys.toList();
    if (accumulated.isEmpty) return;
    // 去重＝條碼原始內容（同一張還在畫面中不重複加入）。
    if (accumulated.every(_seenCodes.contains)) return;

    // **解析主路徑＝TwEin**（官方規格 v1.9；右碼可缺——省略參數）；
    // 後備＝既有解析器（雙保險）。
    final inv = _scanner.parseInvoice(accumulated);
    TransactionDraft? draft;
    if (inv != null) {
      draft = _twEinToDraft(inv);
    } else {
      draft = ImageQrScanner.draftFromQrTexts(accumulated);
    }

    // 左碼在窗但明細未齊（右碼還沒掃到）→ **續等右碼**；窗內左碼已待
    // 超過 2.4 秒仍無右碼 → 左碼先入單（總額/日期/發票號不丟）。
    DateTime? leftSince;
    for (final e in _recentTexts.entries) {
      if (ImageQrScanner.extractOfficialLeft(e.key) != null) {
        if (leftSince == null || e.value.isBefore(leftSince)) {
          leftSince = e.value;
        }
      }
    }
    if (draft == null) {
      if (leftSince != null &&
          now.difference(leftSince) <
              const Duration(milliseconds: 2400)) {
        return; // 續等右碼進窗（T84——html5-qrcode 每碼各別回呼）。
      }
      if (leftSince == null) {
        // 只有右碼（明細碼）——引導對準左側（與 APP 同款提示）。
        if (accumulated.any((t) => t.startsWith('**'))) {
          _flashHint('✓ 偵測到右側明細碼——請再對準左側 QR（發票號那格）');
        }
        return;
      }
      // 窗尾：左碼先入單（後備解析器）。
      draft = ImageQrScanner.draftFromQrTexts(accumulated);
      if (draft == null) return;
    }

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
    if (leftCode != null) _committedLeftCodes.add(leftCode);
    for (final t in accumulated) {
      _seenCodes.add(t);
    }
    ref.read(scanDraftsProvider.notifier).add(ScannedItem(draft: draft));
    _pausedUntil = DateTime.now().add(const Duration(milliseconds: 300));
    setState(() {
      _decodeHits++;
    });
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

  /// 補光（手電筒）開關：html5-qrcode applyVideoConstraints torch，
  /// 無能力或相機未啟動 → 靜默失敗。
  Future<void> _toggleTorch() async {
    await _scanner.toggleTorch();
    if (mounted) {
      setState(() => _torchOn = _scanner.torchOn);
    }
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
    final items = ref.read(scanDraftsProvider).toList();
    await _openReview(items);
    if (!mounted) return;
    ref.read(scanDraftsProvider.notifier).reset();
    setState(() {
      _seenCodes.clear();
    });
  }

  /// 紙本發票手動開卡（PM 2026-11-22：與 APP 同款——加入暫存清單，
  /// 「完成掃描」統一進確認清單；金額/日期/商家/發票號皆手動輸入）。
  void _addBlankDraft() {
    ref.read(scanDraftsProvider.notifier)
        .add(ScannedItem(draft: TransactionDraft.blank(DateTime.now())));
  }

  void _fallbackToFile() {
    _diagTicker?.cancel();
    unawaited(_scanner.stop());
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => const ImportPage()));
  }

  @override
  void dispose() {
    _hintReset?.cancel();
    _diagTicker?.cancel();
    unawaited(_scanner.stop()); // T83：html5-qrcode 停止＋釋放相機。
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
        setState(() {
          _seenCodes.clear();
          _committedLeftCodes.clear();
          _recentTexts.clear();
        });
      }
      // **連續掃描**（關閉＝預設）：掃到第一張 → 自動進確認清單。
      if (!ref.read(continuousScanProvider) &&
          (prev == null || prev.isEmpty) &&
          next.isNotEmpty) {
        _openReview(next);
      }
    });
    final drafts = ref.watch(scanDraftsProvider);
    final count = drafts.length;
    final mode = ref.watch(scanModeProvider);
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
      // **T84**：預覽固定於同一樹狀位置（Column[模式, Expanded(Stack[預覽…])]），
      // 狀態變化只換 Stack 內覆蓋層——platform view 不搬移，video 播放不中斷
      //（starting→live 若搬移子樹，video 被拔離 DOM＝play() 中斷、解碼停擺）。
      body: _preview == null
          ? (_state == _CamState.failed
              ? _buildFailed(context)
              : const Center(child: CircularProgressIndicator()))
          : Column(
              children: [
                // 掃描模式（pwa-0.5.2：置頂按鈕方式）。
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
                          key: const Key('webcam-preview'), child: _preview!),
                      // starting：不透明覆蓋層（reader div 掛載中——
                      // html5-qrcode start 前置條件）。
                      if (_state == _CamState.starting)
                        ColoredBox(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: const Center(
                                child: CircularProgressIndicator())),
                      // failed：不透明覆蓋層（蓋住預覽——與 pwa-0.5.2 同觀感）。
                      if (_state == _CamState.failed)
                        ColoredBox(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: _buildFailed(context)),
                      if (_state == _CamState.live) ...[
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
                        // 切換鏡頭（pwa-0.5.2 版面；iOS＝整頁重載式切換）。
                        Positioned(
                          right: 12,
                          top: 12,
                          child: IconButton(
                            key: const Key('webcam-switch-camera'),
                            tooltip: '切換鏡頭',
                            onPressed: _switchCamera,
                            icon: const Icon(Icons.cameraswitch),
                            color: Colors.white,
                          ),
                        ),
                        // 補光開關（pwa-0.5.2 位置——right:72 讓位切換鏡頭）。
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
                                  color: _torchOn
                                      ? Colors.black
                                      : Colors.white,
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
                        // 紙本發票模式：手動開卡入口。
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
                        // 診斷面板（pwa-0.5.2 格式：幀 N · 命中 N）。
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
                              onTap: () => setState(
                                  () => _diagExpanded = !_diagExpanded),
                              child: Text(
                                _diagExpanded
                                    ? '[$kWebScanAppVersion] 幀 ${_scanner.frameCount} · '
                                        '$_frameInfo · 命中 $_decodeHits'
                                    : '幀 ${_scanner.frameCount} · 命中 $_decodeHits',
                                key: const Key('webcam-diag'),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_state == _CamState.live) ...[
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
                        onChanged: (v) => ref
                            .read(continuousScanProvider.notifier)
                            .set(v),
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
              ],
            ),
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
                unawaited(_scanner
                    .stop()); // 停止舊掃描——重新請求（權限被拒後可再試）
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
