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
    expect(file.uri.pathSegments.last, matches(RegExp(r'^update-\d+\.apk$')));

    final again = await updater.download(url, destination: directory);
    expect(again.path, isNot(file.path));
    expect(await file.exists(), isFalse);
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
    expect(directory.listSync(), isEmpty);
  });

  test('rejects an HTML response with a successful status', () async {
    final updater = ApkUpdater(client: MockClient((_) async =>
        http.Response('<html>download error</html>', 200)));
    addTearDown(updater.close);

    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('discard keeps only a package still inside the grace window', () async {
    final oldApk = File('${directory.path}/update-1.apk')..writeAsBytesSync([1]);
    final oldPart = File('${directory.path}/update-1.apk.part')
      ..writeAsBytesSync([2]);
    final legacy = File('${directory.path}/update.apk')..writeAsBytesSync([3]);
    final fresh = File('${directory.path}/update-2.apk')..writeAsBytesSync([4]);
    final unrelated = File('${directory.path}/notes.txt')..writeAsStringSync('x');
    final stale = DateTime.now().subtract(const Duration(hours: 2));
    await oldApk.setLastModified(stale);
    await oldPart.setLastModified(stale);
    await legacy.setLastModified(stale);

    await ApkUpdater.discardDownloadedPackages(
      directory: directory,
      olderThan: ApkUpdater.downloadedPackageGrace,
    );

    expect(await oldApk.exists(), isFalse);
    expect(await oldPart.exists(), isFalse);
    expect(await legacy.exists(), isFalse);
    expect(await fresh.readAsBytes(), [4]);
    expect(await unrelated.readAsString(), 'x');

    await ApkUpdater.discardDownloadedPackages(directory: directory);
    expect(await fresh.exists(), isFalse);
    expect(await unrelated.readAsString(), 'x');
  });
}
