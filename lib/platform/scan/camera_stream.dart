/// 相機串流控制器（F14 PWA 即時掃描；平台分流——分析期恆選 base，編譯期 CFE 分流）。
///
/// - **web**：`getUserMedia`（後鏡頭）＋`<video>` 預覽＋canvas 取幀（JPEG）。
/// - **native**：暫不支援（SP-2b mobile_scanner）→ start 拋
///   [CameraUnavailableException]，呼叫端回退檔案匯入。
///
/// 詳見 `lib/data/sqlite/db_opener_stub.dart` 註解（stub 型別必須正確）。
///
/// 平台分流工廠：**只能由條件匯出提供**（stub/native/web 各自實作）——
/// 本檔**不得**宣告同名本地函式或實作：Dart 本地宣告會遮蔽條件匯出，
/// 造成所有平台永遠走丟例外（PWA 相機失效根因，DBG-018 2026-11-21）。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

export 'camera_stream_stub.dart'
    if (dart.library.io) 'camera_stream_native.dart'
    if (dart.library.js_interop) 'camera_stream_web.dart';

/// 原生偵測結果（T88——PM 2026-11-25「掃到條碼要有框」）。
class DetectedCode {
  const DetectedCode({required this.text, this.box});

  /// 條碼原始文字。
  final String text;

  /// 偵測框（**video 像素座標系**——native BarcodeDetector boundingBox；
  /// 繪製時由呼叫端做 object-fit:cover 映射。native/stub 無框＝null）。
  final Rect? box;
}

/// 分析用幀（**RGBA 直入**——T89 紅米卡頓修復：跳過 JPEG 編碼＋解碼鏈，
/// 像素直接交 zxing2；native/stub 不提供＝null，呼叫端退回 JPEG 路徑）。
class AnalysisFrame {
  const AnalysisFrame({
    required this.rgba,
    required this.width,
    required this.height,
  });

  /// 像素（RGBA，每像素 4 bytes，row-major）。
  final Uint8List rgba;

  /// 幀寬（px）。
  final int width;

  /// 幀高（px）。
  final int height;
}

class CameraUnavailableException implements Exception {
  const CameraUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'CameraUnavailableException: $message';
}

abstract interface class CameraStreamController {
  /// 啟動相機（請求權限）→ 成功回傳**預覽 Widget**；失敗拋
  /// [CameraUnavailableException]（拒絕/無相機/非 https）。
  Future<Widget> start();

  /// 擷取目前畫面（JPEG bytes）；無畫面回 null。
  Future<Uint8List?> captureFrame();

  /// 擷取**分析用**幀（RGBA 直入——僅 web 實作；native/stub 回 null）。
  /// 與 [captureFrame] 分離：解碼 tick 用 RGBA（零轉檔），照片只在
  /// 命中時擷一次 JPEG（T89）。
  ///
  /// [region]（T91，**video 像素座標**）：只取該子區的 RGBA（`getImageData`
  /// 子矩形——比全幅便宜，ROI 解碼面積 ≈ 全幅 1/8）；回傳 [AnalysisFrame]
  /// 的 width/height 即子區尺寸。省略（null）＝全幅（現行行為）。
  Future<AnalysisFrame?> captureAnalysisFrame({Rect? region});

  /// 預覽**播放恢復**（T89b——行動版瀏覽器 video 元素被重掛（確認清單
  /// 返回的 platform view 重建）後播放管線可能中斷＝黑畫面；重綁串流
  /// ＋補 play（不重新談判相機）。native/stub：no-op。
  Future<void> resumePreview();

  /// 預覽**完全重建**（T89c——iOS WebKit 對重掛的 video/slot 殘留
  /// 轉場/尺寸狀態，重掛同元素治不了）：新 video 元素＋新串流＋新
  /// viewType slot＝「第一次啟動行為」。**僅 web/iOS 實作**——非 iOS
  /// 回 null（呼叫端維持 [resumePreview] 輕量路徑）。native/stub：null。
  Future<Widget?> restartPreviewFresh();

  /// 停止串流並釋放。
  void dispose();

  /// 切換相機（前/後循環；PM 2026-11-21 按鈕需求）——僅 web 實作有意義；
  /// 失敗靜默維持現有鏡頭。
  Future<void> switchCamera();

  /// 診斷資訊（目前朝向／切換結果——掃描頁診斷面板顯示，定位用）。
  String get diagInfo;

  /// 目前視訊解析度字串（診斷行顯示——判斷 getUserMedia 是否被瀏覽器降級；
  /// PM 2026-11-22 Mac PWA 定位用）。無資訊回空字串。
  String get resolutionInfo;

  /// 瀏覽器**原生條碼偵測器**（BarcodeDetector API）可用？（T10——
  /// Chrome/Edge/Safari 17+；品質遠勝 zxing2。僅 web 實作回 true。）
  bool get hasNativeBarcodeDetector;

  /// 以原生偵測器掃描目前畫面 → 條碼清單（不支援/無結果/錯誤 → 空）。
  ///
  /// [region]（T91，**video 像素座標**）：只偵測該子區——web 實作將 video
  /// 裁切至 ROI（**放大至長邊 640px，上限 2×**——小碼模組放大＝原生偵測
  /// 更易命中）再偵測；回傳框已反算回 video 座標（繪製契約不變）。
  /// 省略（null）＝全幅（現行行為）。
  Future<List<DetectedCode>> detectNativeBarcodes({Rect? region});

  /// 相機**補光（手電筒）**是否可用？（web：track capabilities 有 torch；
  /// native：mobile_scanner torch）。無能力 → 開關隱藏。
  bool get torchSupported;

  /// zoom 能力（T82——web 端 getUserMedia capabilities 探測；
  /// native 掃描頁自管 zoom 按鈕不走此介面）。
  bool get zoomSupported;

  /// 變焦（正規化 0~1——0=1×、1=最大；不支援＝靜默）。
  Future<void> setZoom(double normalized);

  /// **點選對焦**（PM 2026-11-28）：對 [nx],[ny]（video 正規化 0~1）施加
  /// pointsOfInterest——瀏覽器支援度不一（best-effort 靜默失敗）。
  Future<void> focusAt(double nx, double ny);

  /// 切換補光開啟/關閉。（無能力或相機未啟動 → 靜默失敗。）
  Future<void> toggleTorch();

  /// 補光目前狀態（on/off）。UI 按鈕顏色依此顯示。
  bool get torchOn;
}
