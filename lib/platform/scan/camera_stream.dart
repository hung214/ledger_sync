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

  /// 視訊長寬比（w/h；未就緒回 null——web 預覽 contain 幾何用）。
  double? get videoAspect;

  /// video 元素實際渲染尺寸＋readyState（診斷——PM 2026-11-23
  /// 「預覽有鏡頭但沒顯示」定位用）。
  String get elementInfo;

  /// 瀏覽器**原生條碼偵測器**（BarcodeDetector API）可用？（T10——
  /// Chrome/Edge/Safari 17+；品質遠勝 zxing2。僅 web 實作回 true。）
  bool get hasNativeBarcodeDetector;

  /// 以原生偵測器掃描目前畫面 → rawValue 清單（不支援/無結果/錯誤 → 空）。
  /// 內含**中央裁切變焦分層**（整張→70%→50%→四象限——PM 2026-11-23：
  /// 「要喬很久角度距離」的容許度修法）。
  Future<List<String>> detectNativeBarcodes();

  /// 解碼迴圈建議間隔（原生偵測器快→700ms；zxing2 慢→1200ms）。
  Duration get decodeInterval;

  /// 相機**變焦**支援？（web：track capabilities 有 zoom）。
  bool get zoomSupported;

  /// 設定變焦（正規化 0~1；web：track zoom constraint）。
  Future<void> setZoom(double normalized);

  /// 最近一次原生偵測的**條碼區域**（正規化 0~1，top-left 原點；畫綠框用）
  /// 與參考幀尺寸。null＝無。
  ({List<Rect> boxes, Size frameSize})? get lastNativeBoxes;
}
