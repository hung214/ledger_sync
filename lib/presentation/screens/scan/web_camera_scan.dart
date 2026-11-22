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

/// 解碼函式 provider（測試可覆寫；預設＝**相機幀輕量解碼**——只解整張＋
/// 左右半 3 區；完整 9 區掃描在行動裝置主執行緒上每幀可達數秒，塞死 UI）。
final webCameraDecodeProvider = Provider<TransactionDraft? Function(Uint8List)>(
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
  final Set<String> _seenSignatures = <String>{};
  int _addedFromThisSession = 0;
  // 診斷面板（PM 2026-11-21「無法正確掃描」定位用）：
  int _frames = 0; // 取幀計數
  String _frameInfo = '—'; // 最近取幀狀態（大小／無畫面）
  int _decodeHits = 0; // 解碼命中次數
  bool _decoding = false; // 解碼中跳過新幀（同步解碼塞主執行緒——疊加即卡死）
  int _decodeMs = 0; // 最近一次解碼耗時（面板顯示——行動裝置效能定位）

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
      });
      _loop = Timer.periodic(
          const Duration(milliseconds: 1200), (_) => _tryDecode());
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
    final bytes = await _controller.captureFrame();
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _frameInfo = '無畫面');
      return;
    }
    setState(() {
      _frames++;
      _frameInfo = '${bytes.length} B';
    });
    _decoding = true;
    final sw = Stopwatch()..start();
    final draft = ref.read(webCameraDecodeProvider)(bytes);
    sw.stop();
    _decoding = false;
    if (mounted) setState(() => _decodeMs = sw.elapsedMilliseconds);
    if (draft == null) return; // 無 QR——繼續取景
    if (mounted) setState(() => _decodeHits++);
    final sig = '${draft.totalMinor.value}|${draft.date.value}'
        '|${draft.merchant.value ?? ''}';
    if (!_seenSignatures.add(sig)) return; // 同張去重（QR 還在畫面中）
    ref.read(scanDraftsProvider.notifier).add(
        ScannedItem(draft: draft, photoBytes: bytes));
    if (mounted) setState(() => _addedFromThisSession++);
  }

  Future<void> _finish() async {
    _loop?.cancel();
    final items = ref.read(scanDraftsProvider).toList();
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReviewPage(items: items)));
    if (!mounted) return;
    ref.read(scanDraftsProvider.notifier).reset();
    setState(() {
      _addedFromThisSession = 0;
      _seenSignatures.clear();
    });
    _loop = Timer.periodic(
        const Duration(milliseconds: 1200), (_) => _tryDecode()); // 繼續掃
  }

  /// 紙本發票（PWA）：web 無線性條碼解碼（scan_policy 平台分流）→
  /// **手動開卡**（金額/日期/商家/發票號皆手動；PM 2026-11-22）。
  Future<void> _openPaperManual() async {
    _loop?.cancel();
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReviewPage(items: [
              ScannedItem(draft: TransactionDraft.blank(DateTime.now())),
            ])));
    if (!mounted) return;
    ref.read(scanDraftsProvider.notifier).reset();
    setState(() => _addedFromThisSession = 0);
    _loop = Timer.periodic(
        const Duration(milliseconds: 1200), (_) => _tryDecode());
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              KeyedSubtree(
                  key: const Key('webcam-preview'), child: _preview!),
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
                  child: Text(
                    '[$kWebScanAppVersion] 幀 $_frames · $_frameInfo · 命中 $_decodeHits · 解 $_decodeMs ms'
                    '${_controller.diagInfo.isEmpty ? '' : ' · ${_controller.diagInfo}'}',
                    key: const Key('webcam-diag'),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              TextButton(
                key: const Key('webcam-paper-manual'),
                onPressed: _openPaperManual,
                child: const Text('紙本發票（手動）'),
              ),
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
