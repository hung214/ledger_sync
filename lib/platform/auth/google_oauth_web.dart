/// Google Identity Services（GIS）OAuth **token** client——web（PWA）專用
/// （P5.2；tasks §6.0b）。以 JS interop 呼叫 `google.accounts.oauth2`。
///
/// - scope：`drive.appdata`（appDataFolder 專屬；SDD §5.5.1）。
/// - token 存記憶體（~1 小時效期；到期靜默續取 `prompt:'none'`——
///   需使用者已有 Google session；無 session 時由 UI 觸發 [GisBearerClient.signIn]）。
/// - **Origin 授權**：頁面 origin 須登記於 OAuth Web 用戶端之
///   「Authorized JavaScript origins」（開發＝http://localhost；正式＝部署網址；
///   見 `specs/plan/pm-actions.md` §1.1）。
///
/// 本檔僅供 **Web 目標**匯入（dart:js_interop）；native 不得 import。
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../cloud/cloud_storage_adapter.dart';
import '../cloud/drive/google_apis_drive_api.dart';

const String kDriveAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';

bool _gisLoaded = false;

/// 載入 GIS script（單例；失敗拋例外）。
Future<void> loadGoogleIdentityServices() async {
  if (_gisLoaded) return;
  final doc = web.document;
  final script =
      doc.createElement('script') as web.HTMLScriptElement;
  script.src = 'https://accounts.google.com/gsi/client';
  script.async = true;
  final c = Completer<void>();
  script.onload = ((web.Event _) => c.complete()).toJS;
  script.onerror = ((web.Event _) =>
          c.completeError(StateError('GIS script 載入失敗（網路/origin）')))
      .toJS;
  doc.head!.appendChild(script);
  await c.future.timeout(const Duration(seconds: 12));
  _gisLoaded = true;
}

// ── GIS JS interop（extension types）────────────────────────

@JS('google.accounts.oauth2')
external _GisOauth2 _oauth2();

extension type _GisOauth2._(JSObject _) implements JSObject {
  external _GisTokenClient initTokenClient(_GisTokenClientConfig config);
}

extension type _GisTokenClientConfig._(JSObject _) implements JSObject {
  external factory _GisTokenClientConfig({
    // ignore: non_constant_identifier_names — GIS JS API 屬性名（snake_case）
    JSString client_id,
    JSString scope,
    JSFunction callback,
  });
}

extension type _GisTokenClient._(JSObject _) implements JSObject {
  external void requestAccessToken([_GisPromptConfig? config]);
}

extension type _GisPromptConfig._(JSObject _) implements JSObject {
  external factory _GisPromptConfig({JSString prompt});
}

extension type _GisTokenResponse._(JSObject _) implements JSObject {
  // ignore: non_constant_identifier_names — GIS JS API 屬性名
  external JSString? get access_token;
  // ignore: non_constant_identifier_names — GIS JS API 屬性名
  external JSNumber? get expires_in;
  external JSString? get error;
}

/// GIS 取得之 token（記憶體保存；不落任何儲存——安全基線）。
class _GisToken {
  _GisToken(this.accessToken, this.expiresAt);
  final String accessToken;
  final DateTime expiresAt;
  bool get valid => DateTime.now().isBefore(expiresAt);
}

/// GIS bearer client：實作 [AuthorizedClient]——自動附 `Authorization`、
/// 靜默續取、401 自動失效重取（下次請求時）。
class GisBearerClient extends http.BaseClient implements AuthorizedClient {
  GisBearerClient(this.clientId, {http.Client? inner})
      : _inner = inner ?? http.Client();

  final String clientId;
  final http.Client _inner;

  _GisToken? _token;
  _GisTokenClient? _tokenClient;

  @override
  bool get hasValidToken => _token?.valid ?? false;

  /// 互動式登入（UI 按鈕觸發；P6/P8 接 Settings 同步頁）。
  Future<void> signIn() => _acquire(interactive: true);

  Future<void> _acquire({required bool interactive}) async {
    await loadGoogleIdentityServices();
    _tokenClient ??= _oauth2().initTokenClient(_GisTokenClientConfig(
      client_id: clientId.toJS,
      scope: kDriveAppDataScope.toJS,
      callback: ((JSObject r) {
        final resp = _GisTokenResponse._(r);
        // 完成路徑：由 Completer 接手（見下方 requestToken）。
        _lastResponse = resp;
        _responseReady?.complete();
      }).toJS,
    ));

    final resp = await _requestToken(interactive: interactive);
    final errRaw = resp.error;
    if (errRaw != null && errRaw.toDart.isNotEmpty) {
      throw CloudUnavailableException('Google 授權失敗：${errRaw.toDart}');
    }
    final accessRaw = resp.access_token;
    if (accessRaw == null || accessRaw.toDart.isEmpty) {
      throw const CloudUnavailableException('Google 授權未回傳 token');
    }
    final expRaw = resp.expires_in;
    final expiresIn = expRaw == null ? 3600 : expRaw.toDartInt;
    _token = _GisToken(accessRaw.toDart,
        DateTime.now().add(Duration(seconds: expiresIn - 60)));
  }

  _GisTokenResponse? _lastResponse;
  Completer<void>? _responseReady;

  Future<_GisTokenResponse> _requestToken({required bool interactive}) {
    final ready = _responseReady = Completer<void>();
    _tokenClient!.requestAccessToken(
        _GisPromptConfig(prompt: (interactive ? 'consent' : 'none').toJS));
    return ready.future.then((_) {
      final r = _lastResponse!;
      _lastResponse = null;
      _responseReady = null;
      return r;
    });
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!hasValidToken) {
      // 靜默續取（無 session 會失敗→以 CloudUnavailableException 呈現，
      // UI 由 signIn() 觸發互動式登入——P6/P8 接線）。
      await _acquire(interactive: false);
    }
    final token = _token!;
    request.headers['Authorization'] = 'Bearer ${token.accessToken}';
    final resp = await _inner.send(request);
    if (resp.statusCode == 401) {
      _token = null; // 失效：下次請求重新靜默取
    }
    return resp;
  }
}
