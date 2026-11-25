/// TwEin 解析 stub（VM 測試／native 編譯——JS 全域不存在，永遠回 null；
/// 呼叫端走後備解析器 [ImageQrScanner.draftFromQrTexts]）。
library;

import 'tw_ein_parse.dart';

class TwEinParserStub implements TwEinParser {
  const TwEinParserStub();

  @override
  TwEinInvoice? parseInvoice(List<String> texts) => null;
}

/// 全域實例（VM/native 永遠回 null——呼叫端走後備解析器）。
const TwEinParser twEinParser = TwEinParserStub();
