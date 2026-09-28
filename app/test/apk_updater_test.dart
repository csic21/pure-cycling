import 'dart:io';

import 'package:cycling_app/core/updates/apk_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('apk-updater-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  final url = Uri.parse('https://github.com/example/app/releases/download/v2/app.apk');
  final apkBytes = [0x50, 0x4b, 0x03, 0x04, 1, 2, 3];

  test('follows HTTPS redirects and saves the complete APK', () async {
    final requests = <Uri>[];
    final updater = ApkUpdater(client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.host == 'github.com') {
        return http.Response('', 302, headers: {
          'location': 'https://release-assets.githubusercontent.com/app.apk',
        });
      }
      return http.Response.bytes(apkBytes, 200);
    }));
    addTearDown(updater.close);
    var progress = 0;

    final file = await updater.download(
      url,
      destination: directory,
      onProgress: (received, _) => progress = received,
    );

    expect(requests.map((uri) => uri.host), [
      'github.com',
      'release-assets.githubusercontent.com',
    ]);
    expect(await file.readAsBytes(), apkBytes);
    expect(progress, apkBytes.length);
  });

  test('rejects a redirect to HTTP and leaves no partial APK', () async {
    final updater = ApkUpdater(client: MockClient((_) async => http.Response(
      '',
      302,
      headers: {'location': 'http://example.com/app.apk'},
    )));
    addTearDown(updater.close);

    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(await File('${directory.path}/update.apk.part').exists(), isFalse);
  });

  test('rejects an HTML response with a successful status', () async {
    final updater = ApkUpdater(client: MockClient((_) async =>
        http.Response('<html>download error</html>', 200)));
    addTearDown(updater.close);

    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(await File('${directory.path}/update.apk').exists(), isFalse);
  });
}
