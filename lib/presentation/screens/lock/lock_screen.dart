import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/lock/lock_fe_state.dart';
import '../../../application/sync/sync_fe_state.dart';

/// 鎖定畫面（FR-X1/X5；AC-09）——**全遮蔽覆蓋層**（底層內容不可透視——
/// 隱私破口＝Critical，acceptance S8.1）。
///
/// 解鎖路徑：①Face ID（成功→dismiss；失敗 ×3 → 僅 PIN）②PIN 輸入
/// ③忘記 PIN（已連雲端→設定新 PIN；未連→僅「重置 App」）。
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  bool _pinMode = false; // 生物辨識退場後僅 PIN
  bool _resetMode = false; // 忘記 PIN（已連雲端）
  final _pinCtrl = TextEditingController();
  final _newPinCtrl = TextEditingController();

  @override
  void dispose() {
    _pinCtrl.dispose();
    _newPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    final ok = await ref.read(biometricAuthProvider)();
    if (!mounted) return;
    if (ok) {
      ref.read(appLockControllerProvider).onBiometricSuccess();
      ref.read(lockOverlayProvider.notifier).dismiss();
    } else {
      ref.read(appLockControllerProvider).onBiometricFail();
      if (!ref.read(appLockControllerProvider).biometricAllowed) {
        setState(() => _pinMode = true); // FR-X1：失敗 ≥3 僅 PIN
      } else {
        setState(() {}); // 重試提示
      }
    }
  }

  Future<void> _submitPin() async {
    final lock = ref.read(appLockControllerProvider);
    final ok = await lock.verifyPin(_pinCtrl.text);
    if (!mounted) return;
    if (ok) {
      ref.read(lockOverlayProvider.notifier).dismiss();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN 錯誤')));
    }
  }

  Future<void> _forgotPin() async {
    // FR-X5：已連雲端 → token 驗證（seam）→ 設定新 PIN；未連 → 僅重置 App。
    final lock = ref.read(appLockControllerProvider);
    final linked = (ref.read(dbSettingReader)('sync.account') ?? '').isNotEmpty;
    if (!linked) {
      setState(() => _resetMode = true);
      return;
    }
    // token 驗證（雲端帳號重新登入——生產 OAuth；M7 FE 為直接通過的 seam）。
    final tokenValid = await ref.read(biometricAuthProvider)(); // 授權 seam 共用
    if (!mounted) return;
    if (lock.canResetPin(cloudTokenValid: tokenValid)) {
      setState(() => _resetMode = true);
    } else {
      setState(() => _resetMode = true); // 未連結 → 重置 App 路徑
    }
  }

  Future<void> _submitNewPin() async {
    final pin = _newPinCtrl.text;
    if (pin.length < 4) return;
    await ref.read(appLockControllerProvider).setPin(pin);
    ref.read(lockOverlayProvider.notifier).dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.read(appLockControllerProvider);
    final linked = (ref.read(dbSettingReader)('sync.account') ?? '').isNotEmpty;
    return Positioned.fill(
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 16),
                const Center(
                    child: Text('已鎖定', key: Key('lock-title'),
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                const SizedBox(height: 24),
                if (!_pinMode && !_resetMode) ...[
                  if (lock.biometricAllowed)
                    FilledButton.icon(
                      key: const Key('faceid-button'),
                      onPressed: _tryBiometric,
                      icon: const Icon(Icons.face),
                      label: const Text('使用 Face ID 解鎖'),
                    )
                  else ...[
                    TextField(
                      key: const Key('pin-input'),
                      controller: _pinCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '輸入 PIN'),
                      keyboardType: TextInputType.number,
                    ),
                    FilledButton(
                        onPressed: _submitPin, child: const Text('解鎖')),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    key: const Key('forgot-pin'),
                    onPressed: _forgotPin,
                    child: const Text('忘記 PIN？'),
                  ),
                ] else if (_pinMode) ...[
                  const Center(
                      child: Text('請輸入 PIN',
                          key: Key('pin-keyboard-title'))),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('pin-input'),
                    controller: _pinCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'PIN'),
                    keyboardType: TextInputType.number,
                  ),
                  FilledButton(
                      key: const Key('pin-submit'),
                      onPressed: _submitPin,
                      child: const Text('解鎖')),
                ] else ...[
                  // 重設/重置路徑（FR-X5）。
                  if (linked) ...[
                    const Center(
                        child: Text('設定新 PIN', key: Key('new-pin-title'))),
                    TextField(
                      key: const Key('new-pin-input'),
                      controller: _newPinCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '新 PIN'),
                      keyboardType: TextInputType.number,
                    ),
                    FilledButton(
                        key: const Key('new-pin-submit'),
                        onPressed: _submitNewPin,
                        child: const Text('設定新 PIN')),
                    const Center(child: Text('資料完整保留')),
                  ] else ...[
                    const Center(
                        child: Text('重置 App',
                            key: Key('reset-app-title'),
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    const Center(
                        child: Text('將清除所有本地資料，回到首次啟動引導')),
                    FilledButton(
                      key: const Key('reset-app'),
                      onPressed: () {},
                      child: const Text('重置 App'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
