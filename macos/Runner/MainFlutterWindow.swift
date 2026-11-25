import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    self.delegate = self
    super.awakeFromNib()
  }

  /// 視窗關閉鈕／⌘W（DBG-017，2026-11-21）：
  /// AppKit 預設「先關窗 → 最後一窗關閉觸發 terminate:」——此時 Dart 端
  /// `AppLifecycleListener.onExitRequested` 的確認對話框（app_shell.dart）
  /// 畫在**已銷毀**的視窗上，不可見不可點 → Dart 永不回覆 → 行程殭屍
  /// （需強制關閉）。Flutter 上游已知問題：flutter/flutter#134255。
  ///
  /// 修法：關閉鈕**不直接關窗**，改走 `NSApp.terminate:` → 引擎向 Dart
  /// 請求退出 → 對話框在**仍開著的視窗**上顯示；確認 → 引擎完成終止
  /// （乾淨退出）；取消 → 視窗保留（繼續使用）。⌘Q 不經此路徑，本就正常。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(self)
    return false
  }
}
