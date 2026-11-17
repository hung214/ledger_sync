import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/appearance/theme_mode_state.dart';
import '../../../application/providers.dart';
import 'account_settings_page.dart';
import 'category_settings_page.dart';
import 'data_management_page.dart';
import 'help_page.dart';
import 'settings_sync_page.dart';

/// 設定 Hub（SDD §8 設定群；M7 恢復入口＋M8 設定群）：
/// 同步／資料／帳戶管理（FR-A7）／分類管理（FR-B1）／外觀（FR-O1）。
///
/// 測試 keys：settings-sync／settings-data-management／settings-accounts／
/// settings-categories／theme-system／theme-light／theme-dark。
class SettingsHubPage extends ConsumerWidget {
  const SettingsHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final accountCount = ref.watch(dbProvider).allAccounts().length;
    final categoryCount = ref.watch(dbProvider).categoriesByKind('expense').length +
        ref.watch(dbProvider).categoriesByKind('income').length;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const _SectionLabel('同步'),
          ListTile(
            key: const Key('settings-sync'),
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('雲端備份'),
            subtitle: const Text('備份到 Google Drive、跨裝置同步、衝突檢視'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsSyncPage())),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const _SectionLabel('資料'),
          ListTile(
            key: const Key('settings-accounts'),
            leading: const Icon(Icons.account_balance_wallet_outlined),
            title: const Text('帳戶管理'),
            subtitle: Text('名稱、類型、合併計算（$accountCount 個帳戶）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const AccountSettingsPage())),
          ),
          ListTile(
            key: const Key('settings-categories'),
            leading: const Icon(Icons.label_outline),
            title: const Text('分類管理'),
            subtitle: Text('自訂、排序、子分類（$categoryCount 個分類）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const CategorySettingsPage())),
          ),
          ListTile(
            key: const Key('settings-help'),
            leading: const Icon(Icons.help_outline),
            title: const Text('使用說明'),
            subtitle: const Text('安裝更新／備份還原／匯入／常見問題'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HelpPage())),
          ),
          ListTile(
            key: const Key('settings-data-management'),
            leading: const Icon(Icons.storage_outlined),
            title: const Text('資料管理'),
            subtitle: const Text('清空資料（三重防護）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const DataManagementPage())),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const _SectionLabel('外觀'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (mode, label, key) in const [
                  (ThemeMode.system, '跟隨系統', 'theme-system'),
                  (ThemeMode.light, '淺色', 'theme-light'),
                  (ThemeMode.dark, '深色', 'theme-dark'),
                ])
                  ChoiceChip(
                    key: Key(key),
                    label: Text(label),
                    selected: themeMode == mode,
                    onSelected: (_) => ref.read(themeModeProvider.notifier).set(mode),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
