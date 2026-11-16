import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ledger_sync/platform/cloud/cloud_storage_adapter.dart';
import 'package:ledger_sync/platform/cloud/drive/google_apis_drive_api.dart';

/// GoogleApisDriveApi REST 語意 seam 測試（P5.3；tasks §6.0b）。
///
/// 以 fake http client 驗證請求形狀（方法/路徑/query/body）與解析——
/// 真實 Drive 憑證就緒後（pm-actions §1.1），僅換 GisBearerClient／loopback
/// client 即上線（seam 設計初衷）。
void main() {
  late _FakeAuthorizedClient client;
  late GoogleApisDriveApi api;

  setUp(() {
    client = _FakeAuthorizedClient();
    api = GoogleApisDriveApi(client);
  });

  test('rootFolderId＝appDataFolder 別名；isAuthorized 反映 client 狀態', () async {
    expect(await api.rootFolderId(), 'appDataFolder');
    client.hasToken = false;
    expect(await api.isAuthorized(), isFalse);
    client.hasToken = true;
    expect(await api.isAuthorized(), isTrue);
  });

  test('listChildren：query 帶 q/fields/spaces；解析檔案＋資料夾旗標', () async {
    client.responses.add(http.Response(
        jsonEncode({
          'files': [
            {'id': 'f1', 'name': 'vault.json', 'mimeType': 'application/json'},
            {
              'id': 'd1',
              'name': 'blobs',
              'mimeType': 'application/vnd.google-apps.folder'
            },
          ]
        }),
        200));
    final entries = await api.listChildren('appDataFolder');
    expect(entries, hasLength(2));
    expect(entries[0].id, 'f1');
    expect(entries[0].isFolder, isFalse);
    expect(entries[1].isFolder, isTrue, reason: 'mimeType=folder → isFolder');
    final uri = client.requests.single.url;
    expect(uri.path, '/drive/v3/files');
    expect(uri.queryParameters['q'],
        "'appDataFolder' in parents and trashed = false");
    expect(uri.queryParameters['spaces'], 'appDataFolder');
    expect(uri.queryParameters['fields'], contains('files(id,name,mimeType)'));
  });

  test('uploadFile（新建）：resumable 起始 POST＋單段 PUT 內容', () async {
    client.responses.addAll([
      http.Response('', 200, headers: {
        'location': 'https://www.googleapis.com/upload/session/abc'
      }),
      http.Response(jsonEncode({'id': 'new-1'}), 200),
    ]);
    final id = await api.uploadFile(
        name: 'devices/d-A.json',
        parentId: 'appDataFolder',
        bytes: Uint8List.fromList(utf8.encode('{}')));
    expect(id, 'new-1');
    expect(client.requests, hasLength(2));
    expect(client.requests[0].method, 'POST');
    expect(client.requests[0].url.path, '/upload/drive/v3/files');
    expect(
        client.requests[0].url.queryParameters['uploadType'], 'resumable');
    final meta = jsonDecode(utf8.decode(_body(client.requests[0])))
        as Map<String, Object?>;
    expect(meta['name'], 'devices/d-A.json');
    expect(meta['parents'], ['appDataFolder']);
    expect(client.requests[1].method, 'PUT');
    expect(client.requests[1].url.toString(), contains('/upload/session/abc'));
    expect(utf8.decode(_body(client.requests[1])), '{}');
  });

  test('uploadFile（同名覆寫）：PATCH files/{id} 起始；metadata 不含 parents', () async {
    client.responses.addAll([
      http.Response('', 200, headers: {'location': 'https://s/x'}),
      http.Response(jsonEncode({'id': 'old-1'}), 200),
    ]);
    await api.uploadFile(
        name: 'vault.json',
        parentId: 'appDataFolder',
        bytes: Uint8List.fromList(utf8.encode('v2')),
        fileId: 'old-1');
    expect(client.requests[0].method, 'PATCH');
    expect(client.requests[0].url.path, '/upload/drive/v3/files/old-1');
    final meta = jsonDecode(utf8.decode(_body(client.requests[0]))) as Map;
    expect(meta.containsKey('parents'), isFalse,
        reason: '覆寫不動 parents（避免搬移）');
  });

  test('downloadFile：alt=media；404→null；deleteFile：DELETE', () async {
    client.responses.add(http.Response('BYTES', 200));
    final bytes = await api.downloadFile('f1');
    expect(utf8.decode(bytes!), 'BYTES');
    expect(client.requests.single.url.queryParameters['alt'], 'media');

    client.responses.add(http.Response('', 404));
    expect(await api.downloadFile('missing'), isNull);

    client.responses.add(http.Response('', 204));
    await api.deleteFile('f1');
    expect(client.requests.last.method, 'DELETE');
    expect(client.requests.last.url.path, '/drive/v3/files/f1');
  });

  test('非 2xx → CloudUnavailableException（SDD §9 重試語意）', () async {
    client.responses.add(http.Response('rate limited', 403));
    await expectLater(
        api.listChildren('appDataFolder'), throwsCloudUnavailable);
  });
}

/// http.BaseRequest 無 bodyBytes——API 一律送 http.Request，取其本體。
Uint8List _body(http.BaseRequest r) => (r as http.Request).bodyBytes;

final Matcher throwsCloudUnavailable =
    throwsA(isA<CloudUnavailableException>());

class _FakeAuthorizedClient extends http.BaseClient
    implements AuthorizedClient {
  bool hasToken = true;
  final requests = <http.BaseRequest>[];
  final responses = <http.Response>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final resp = responses.removeAt(0);
    return http.StreamedResponse(
        Stream.value(resp.bodyBytes.isEmpty
            ? Uint8List(0)
            : Uint8List.fromList(resp.bodyBytes)),
        resp.statusCode,
        headers: resp.headers);
  }

  @override
  bool get hasValidToken => hasToken;
}
