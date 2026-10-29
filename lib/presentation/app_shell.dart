import 'package:flutter/material.dart';
import 'dart:ui' show AppExitResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/appearance/theme_mode_state.dart';
import '../application/providers.dart';
import '../core/version.dart';
import 'screens/lock/lock_gate.dart';
import 'screens/main_shell_page.dart';
import 'theme/app_theme.dart';

/// M1 主殼 App（真實介面）。
///
/// 視窗標題帶版本號（PM 要求：軟體內可見版本；main.dart 以
/// --dart-define=APP_VERSION 注入，本機顯示 dev）。
/// 測試以 `UncontrolledProviderScope(overrides: [dbProvider...])` 包裹注入。
/// 主題：M7 UI 統整——buildAppTheme 唯一入口；**themeMode 由
/// themeModeProvider 控制（FR-O1：跟隨系統/淺色/深色——設定→外觀）**。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _navKey = GlobalKey<NavigatorState>();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // 關閉 App 前確認（PM 2026-10-29）：桌面按 ⌘W／視窗關閉鈕／退出 → 先跳確認。
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// 退出請求（Flutter 桌面：⌘W／關閉視窗／系統退出皆走此路徑）。
  ///
  /// 回 [AppExitResponse.cancel] → **不關閉**（使用者取消）；`exit` → 關閉。
  /// 確認後順手關閉 DB（乾淨收尾；WAL 本身亦安全）。
  Future<AppExitResponse> _onExitRequested() async {
    final ctx = _navKey.currentContext;
    if (ctx == null) return AppExitResponse.exit;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        key: const Key('app-exit-dialog'),
        title: const Text('確定要關閉 LedgerSync？'),
        content: const Text('未完成的輸入不會保留。已儲存的記帳資料不受影響。'),
        actions: [
          TextButton(
            key: const Key('app-exit-cancel'),
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('繼續使用'),
          ),
          FilledButton(
            key: const Key('app-exit-confirm'),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
    if (ok != true) return AppExitResponse.cancel;
    try {
      ref.read(dbProvider).close();
    } catch (_) {
      // 收尾失敗不阻擋關閉（SQLite WAL 亦安全）。
    }
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      navigatorKey: _navKey,
      title: appVersion == 'dev' ? 'LedgerSync' : 'LedgerSync v$appVersion',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: themeMode,
      home: const LockGate(child: MainShellPage()),
    );
  }
}
