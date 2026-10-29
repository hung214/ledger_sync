import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_sync/application/first_run_bootstrap.dart';
import 'package:ledger_sync/application/providers.dart';
import 'package:ledger_sync/application/sync/sync_coordinator.dart';
import 'package:ledger_sync/presentation/app_shell.dart';

import '../helpers/db_fixture.dart';
import '../helpers/in_memory_cloud_adapter.dart';

/// 關閉 App 前確認（PM 2026-10-29：「要有關閉視窗的快捷，關閉前需要有提示確認視窗」）。
///
/// Flutter 桌面的退出請求（⌘W／關閉視窗鈕／系統退出）皆走
/// `AppLifecycleListener.onExitRequested`——取消＝不關閉；確認＝關閉。
void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = DbFixture.create();
    await FirstRunBootstrap.seedIfNeeded(db);
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      syncCoordinatorProvider.overrideWithValue(
          SyncCoordinator(db, InMemoryCloudAdapter(), deviceId: 'd-A')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const AppShell(),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('退出請求 → 跳確認視窗；按「繼續使用」＝不關閉', (tester) async {
    await pump(tester);

    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-exit-dialog')), findsOneWidget,
        reason: '關閉前必須先跳確認（PM 2026-10-29）');
    expect(find.text('確定要關閉 LedgerSync？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-exit-cancel')));
    await tester.pumpAndSettle();
    expect(await request, AppExitResponse.cancel, reason: '取消 → 不關閉');
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出請求 → 按「關閉」＝允許關閉', (tester) async {
    await pump(tester);

    final request = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-exit-confirm')));
    await tester.pumpAndSettle();

    expect(await request, AppExitResponse.exit, reason: '確認 → 關閉');
    expect(tester.takeException(), isNull);
  });
}
