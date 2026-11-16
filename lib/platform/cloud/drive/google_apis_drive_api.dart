import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../cloud_storage_adapter.dart';
import 'drive_api.dart';

/// 憑證化 HTTP client（[GoogleApisDriveApi] 所需最小面）。
///
/// 實作者：web＝`GisBearerClient`（GIS token；`google_oauth_web.dart`）；
/// 測試＝fake。native（loopback OAuth）就緒後同樣實作本介面。
abstract interface class AuthorizedClient implements http.BaseClient {
  /// 目前是否持有有效 token（**不觸發**任何 UI／網路）。
  bool get hasValidToken;
}

/// Google Drive REST v3 直呼（P5 Web 同步；tasks §6.0b P5.3）。
///
/// **為何手寫 REST 而不引 `googleapis`**：本專案只需 appDataFolder 最小面
/// （`DriveApi` seam 設計初衷）；`http` 為純 Dart → **Web（PWA）可編譯**
/// （Drive API 支援 CORS）。上傳以 **resumable 單段 PUT**——無 multipart
/// 5MB 上限（vault／backups 未來增長不受限）。
///
/// 錯誤語意：非 2xx 一律包 [CloudUnavailableException]
/// （呼叫端依指數退避重試；SDD §9）。
class GoogleApisDriveApi implements DriveApi {
  GoogleApisDriveApi(this._client);

  static const _base = 'https://www.googleapis.com/drive/v3';
  static const _uploadBase = 'https://www.googleapis.com/upload/drive/v3';
  static const _folderMime = 'application/vnd.google-apps.folder';

  final AuthorizedClient _client;

  @override
  Future<bool> isAuthorized() async => _client.hasValidToken;

  @override
  Future<String> rootFolderId() async => 'appDataFolder';

  @override
  Future<String> createFolder(String name, String parentId) async {
    final resp = await _client.post(
      Uri.parse('$_base/files?fields=id'),
      headers: const {'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode({
        'name': name,
        'mimeType': _folderMime,
        'parents': [parentId],
      }),
    );
    if (resp.statusCode != 200) {
      throw CloudUnavailableException('Drive createFolder ${resp.statusCode}');
    }
    return ((jsonDecode(resp.body) as Map<String, Object?>)['id']) as String;
  }

  @override
  Future<List<DriveEntry>> listChildren(String parentId) async {
    final out = <DriveEntry>[];
    String? pageToken;
    do {
      final query = {
        'q': "'$parentId' in parents and trashed = false",
        'fields': 'nextPageToken,files(id,name,mimeType)',
        'pageSize': '200',
        if (parentId == 'appDataFolder') 'spaces': 'appDataFolder',
        'pageToken': ?pageToken,
      };
      final resp = await _client.get(
        Uri.parse('$_base/files').replace(queryParameters: query),
        headers: const {'Content-Type': 'application/json'},
      );
      if (resp.statusCode != 200) {
        throw CloudUnavailableException('Drive list ${resp.statusCode}');
      }
      final json = jsonDecode(resp.body) as Map<String, Object?>;
      final files = (json['files'] as List?) ?? const [];
      for (final f in files) {
        final m = f as Map<String, Object?>;
        out.add(DriveEntry(
          id: m['id'] as String,
          name: m['name'] as String,
          parentId: parentId,
          isFolder: m['mimeType'] == _folderMime,
        ));
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);
    return out;
  }

  @override
  Future<String> uploadFile({
    required String name,
    required String parentId,
    required Uint8List bytes,
    String? fileId,
  }) async {
    // ① resumable session 起始（metadata）。
    final initMethod = fileId == null ? 'POST' : 'PATCH';
    final initUrl = fileId == null
        ? '$_uploadBase/files?uploadType=resumable&fields=id'
        : '$_uploadBase/files/$fileId?uploadType=resumable&fields=id';
    final meta = <String, Object?>{
      'name': name,
      if (fileId == null) 'parents': [parentId],
    };
    final init = http.Request(initMethod, Uri.parse(initUrl))
      ..headers['Content-Type'] = 'application/json; charset=UTF-8'
      ..bodyBytes = utf8.encode(jsonEncode(meta));
    final initResp = await http.Response.fromStream(await _client.send(init));
    if (initResp.statusCode != 200) {
      throw CloudUnavailableException(
          'Drive upload init ${initResp.statusCode}');
    }
    final location = initResp.headers['location'];
    if (location == null || location.isEmpty) {
      throw const CloudUnavailableException('Drive upload 缺 session Location');
    }

    // ② 單段 PUT 內容（resumable session；本專案檔案皆遠低於單段上限）。
    final put = http.Request('PUT', Uri.parse(location))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = bytes;
    final putResp = await http.Response.fromStream(await _client.send(put));
    if (putResp.statusCode != 200 && putResp.statusCode != 201) {
      throw CloudUnavailableException(
          'Drive upload put ${putResp.statusCode}');
    }
    return ((jsonDecode(putResp.body) as Map<String, Object?>)['id']) as String;
  }

  @override
  Future<Uint8List?> downloadFile(String fileId) async {
    final resp =
        await _client.get(Uri.parse('$_base/files/$fileId?alt=media'));
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw CloudUnavailableException(
          'Drive download ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    final resp = await _client.delete(Uri.parse('$_base/files/$fileId'));
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw CloudUnavailableException('Drive delete ${resp.statusCode}');
    }
  }
}
