library;

/// 平台掃描策略（PM 2026-11-22：各平台「掃描成功條件」不同——**代碼明確
/// 區隔**，不再共用單一路徑靠巧合行為）。
///
/// | 平台 | 引擎 | 條碼格式 | 紙本一維條碼 | 已知限制 |
/// |---|---|---|---|---|
/// | iOS | ML Kit（mobile_scanner） | QR＋Code39＋Code128 | ✅ 直接掃 | — |
/// | Android | ML Kit | 同上 | ✅ 直接掃 | — |
/// | macOS | Apple Vision | 同上 | ✅ 直接掃 | 內建相機定焦——小 QR 需近距；**紙本建議掃一維條碼** |
/// | Windows | 無相機（套件限制） | — | ❌ | 檔案匯入 |
/// | Web/PWA | zxing2（純 Dart） | 僅 QR | ❌（無線性條碼解碼） | 解碼器弱於原生——大圖降採樣後備；**紙本＝手動開卡** |
///
/// 原生相機以 [cameraFormats] 設定偵測格式；紙本模式能力以
/// [supportsPaperBarcode] 分流（web 引導手動輸入）。

import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 掃描平台（runtime 判別——與 cameraAvailableProvider 同款模式）。
enum ScanPlatform { ios, android, macos, windows, web }

ScanPlatform detectScanPlatform() => kIsWeb
    ? ScanPlatform.web
    : switch (defaultTargetPlatform) {
        TargetPlatform.iOS => ScanPlatform.ios,
        TargetPlatform.android => ScanPlatform.android,
        TargetPlatform.macOS => ScanPlatform.macos,
        TargetPlatform.windows => ScanPlatform.windows,
        _ => ScanPlatform.macos,
      };

/// 相機偵測格式（原生引擎）：
/// - 電子發票＝QR；
/// - 紙本發票＝官方一維條碼 **Code 39**（規格 §壹；Code 128 為部分店家
///   自印相容——內容不合 19 碼格式者於解析層過濾）。
/// 同時開啟（不隨模式重建 controller）——模式分流在偵測回呼層處理。
List<BarcodeFormat> cameraFormats(ScanPlatform platform) => switch (platform) {
  ScanPlatform.ios || ScanPlatform.android || ScanPlatform.macos => const [
    BarcodeFormat.qrCode,
    BarcodeFormat.code39,
    BarcodeFormat.code128,
  ],
  _ => const [BarcodeFormat.qrCode],
};

/// 紙本發票一維條碼辨識支援——原生引擎（Vision/ML Kit）支援；
/// web（zxing2 僅 QR）不支援 → 紙本模式回退手動開卡。
bool supportsPaperBarcode(ScanPlatform platform) => switch (platform) {
  ScanPlatform.ios || ScanPlatform.android || ScanPlatform.macos => true,
  _ => false,
};
