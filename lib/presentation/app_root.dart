import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sqlite/app_database.dart';
import 'screens/lock/lock_gate.dart';
import 'screens/main_shell_page.dart';
import 'screens/onboarding/first_run_guide_page.dart';
import 'app_shell.dart';

/// App 根分流（F13 首次啟動引導；PM §4#1 決策項實作）。
///
/// **顯示引導的條件**（三者同時）：
/// ① `app.onboarded` 未設定（首次）②帳本**沒有任何交易**（既有使用者升級不受影響；
/// 從備份還原者也不會被引導打擾）③——清空資料會清 settings → 引導重現
/// （兌現 F09 完成頁「下次啟動回到首次設定」的承諾）。
///
/// 引導完成（全新開始/還原/匯入/略過）→ 寫入 `app.onboarded=1` → 進入主殼。
class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key, required this.db});

  final AppDatabase db;

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  late bool _onboarded;

  @override
  void initState() {
    super.initState();
    final hasTx = widget.db.select('SELECT COUNT(*) c FROM transactions WHERE deleted_at IS NULL').first['c'] as int;
    _onboarded =
        widget.db.getSetting('app.onboarded') == '1' || hasTx > 0;
  }

  void _completeOnboarding() {
    widget.db.setSetting('app.onboarded', '1');
    setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    // **引導頁必須在 MaterialApp 內**（PM 2026-11-19 修復：此前未引導時直接
    // 回傳 FirstRunGuidePage——MaterialApp 之外的 Scaffold 無 Directionality
    // → release 版啟動即灰畫面；清空資料後首次觸發此路徑）。
    return AppShell(
      home: _onboarded
          ? const LockGate(child: MainShellPage())
          : LockGate(
              child: FirstRunGuidePage(onDone: _completeOnboarding)),
    );
  }
}
