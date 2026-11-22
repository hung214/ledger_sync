# 掃描真實照片測試報告（PM 2026-11-23 要求記錄）

> 測資來源：PM 提供的 iPhone 實拍發票照片（`test/fixtures/invoices/`，
> HEIC 自動轉 JPEG，4032×3024，個資不入版控）。
> 測試入口：`flutter test test/platform/invoice_photo_fixtures_test.dart`
> （drop-in——放新照片即自動跑，結果印在輸出）。
> 基準定義：IMG_2077＝iPhone 內建相機在該距離可辨識的「距離/大小基準照」。

## 一、逐張結果（2026-11-23 實測）

| 照片 | 類型 | 純 Dart 管線（web/PWA 用，zxing2） | 原生引擎 Vision（APP 檔案匯入，已接線） | OCR 文字辨識（紙本） |
|---|---|---|---|---|
| IMG_2070 | 電子（ibon 列印） | 右碼碎片 `**`（左碼失敗） | ✅ Code39＋左碼＋右碼全解 | — |
| IMG_2071 | 電子（同上） | 0 條 | ✅ 全解 | — |
| IMG_2072 | 電子 | 0 條 | ✅ 左碼＋右碼 | — |
| IMG_2073 | 電子（ibon 21 元） | ✅ 完整入單（發票號/日期/總額/統編/明細） | ✅ | — |
| IMG_2074 | 電子（超商） | 0 條 | ✅ Code39＋左碼＋右碼明細（毛寶洗衣槽去污…） | — |
| IMG_2075 | **紙本**（無條碼） | 0 條（無 QR——預期） | 0 條（**確定無條碼**） | ✅ EF20947672＋日期 2026-09-13 |
| IMG_2076 | **紙本**（無條碼） | 0 條（預期） | 0 條（確定無條碼） | ✅ EF26987585（日期未印→預設今天） |
| IMG_2077 | **電子（距離基準）** | 0 條（zxing2 弱） | ✅ **左碼＋右碼明細全解** | — |

## 二、結論

1. **APP 檔案匯入已改用原生引擎**（`analyzeImage`＝Vision/ML Kit）——
   PM 的距離基準照 2077 與全部電子發票實照**全數可解**（含一維條碼）。
2. **紙本發票（2075/2076）確定無任何條碼**（原生引擎 0 條實證）——
   唯一路徑＝OCR 文字辨識（已實作：iOS/macOS；實測發票號＋日期可抓）。
3. **web/PWA 管線（zxing2）天花板**：僅 IMG_2073 可解——PWA 的檔案匯入
   對小/遠 QR 天生弱（無法用 Vision）；PWA 的**相機**已接瀏覽器原生
   BarcodeDetector（品質接近原生）。PWA 檔案匯入建議：拍清楚或改用 APP。
4. 既有已修的干擾因素：透印去除（背面印刷）、大圖預縮放（12MP→2400）、
   Byte-mode 標頭容錯——於純 Dart 管線生效。

## 三、各平台能力總表（scan_policy 對照）

| 平台 | 相機即時 | 檔案匯入（引擎） | 紙本 OCR |
|---|---|---|---|
| iOS APP | Vision（QR+Code39） | **Vision**（analyzeImage） | ✅ Vision 文字 |
| Android APP | ML Kit | **ML Kit** | ❌（手動） |
| macOS APP | Vision | **Vision** | ✅ Vision 文字 |
| Windows APP | 無相機 | zxing2 | ❌（手動） |
| PWA（web） | BarcodeDetector→zxing2 | zxing2 | ❌（手動） |

## 四、後續（未排期）

- Big5 明細品名亂碼（編碼參數 0 的右碼）——需 Big5 對照表
- IMG_2070 類（QR 模糊）——重拍指引（近距、避透印、QR 佔畫面 1/4）
- PWA 檔案匯入升級（wasm 解碼器）——評估中
