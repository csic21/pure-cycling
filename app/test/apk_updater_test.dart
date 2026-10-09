import 'dart:async';
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

  final url = Uri.parse(
    'https://github.com/example/app/releases/download/v2/app.apk',
  );
  final apkBytes = [0x50, 0x4b, 0x03, 0x04, 1, 2, 3];

  test('follows HTTPS redirects and saves the complete APK', () async {
    final requests = <Uri>[];
    final updater = ApkUpdater(
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'github.com') {
          return http.Response(
            '',
            302,
            headers: {
              'location':
                  'https://release-assets.githubusercontent.com/app.apk',
            },
          );
        }
        return http.Response.bytes(apkBytes, 200);
      }),
    );
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
    final updater = ApkUpdater(
      client: MockClient(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': 'http://example.com/app.apk'},
        ),
      ),
    );
    addTearDown(updater.close);

    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('rejects an HTML response with a successful status', () async {
    final updater = ApkUpdater(
      client: MockClient(
        (_) async => http.Response('<html>download error</html>', 200),
      ),
    );
    addTearDown(updater.close);

    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('rejects an oversized declared package before writing bytes', () async {
    final updater = ApkUpdater(
      client: _StreamClient(
        Stream.value(apkBytes),
        contentLength: 250 * 1024 * 1024 + 1,
      ),
    );
    addTearDown(updater.close);
    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('rejects a truncated body and clears the partial package', () async {
    final updater = ApkUpdater(
      client: _StreamClient(
        Stream.value(apkBytes),
        contentLength: apkBytes.length + 1,
      ),
    );
    addTearDown(updater.close);
    await expectLater(
      updater.download(url, destination: directory),
      throwsA(isA<ApkUpdateException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test(
    'passive cleanup retains one completed package until explicit replacement',
    () async {
      final oldApk = File('${directory.path}/update-1.apk')
        ..writeAsBytesSync([1]);
      final oldPart = File('${directory.path}/update-1.apk.part')
        ..writeAsBytesSync([2]);
      final legacy = File('${directory.path}/update.apk')
        ..writeAsBytesSync([3]);
      final fresh = File('${directory.path}/update-2.apk')
        ..writeAsBytesSync([4]);
      final unrelated = File('${directory.path}/notes.txt')
        ..writeAsStringSync('x');
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
      expect(await fresh.exists(), isTrue);
      expect(await unrelated.readAsString(), 'x');
      // A user-started replacement is the only boundary that retires it.
      final replacement = ApkUpdater(
        client: MockClient((_) async => http.Response.bytes(apkBytes, 200)),
      );
      addTearDown(replacement.close);
      final next = await replacement.download(url, destination: directory);
      expect(await fresh.exists(), isFalse);
      expect(await next.readAsBytes(), apkBytes);
    },
  );
  test('cancel stops a stalled body and removes the partial file', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final updater = ApkUpdater(client: _StreamClient(body.stream));
    final progress = Completer<void>();
    final pending = updater.download(
      url,
      destination: directory,
      onProgress: (_, _) {
        if (!progress.isCompleted) progress.complete();
      },
    );
    final assertion = expectLater(pending, throwsA(isA<ApkUpdateCancelled>()));
    body.add(apkBytes);
    await progress.future;
    updater.close();
    await assertion;
    expect(cancelled, isTrue);
    expect(directory.listSync(), isEmpty);
    await body.close();
    // Cancellation releases the global slot, so a retry is immediately safe.
    final retry = ApkUpdater(
      client: MockClient((_) async => http.Response.bytes(apkBytes, 200)),
    );
    addTearDown(retry.close);
    expect(
      await (await retry.download(url, destination: directory)).readAsBytes(),
      apkBytes,
    );
  });

  test(
    'cleanup skips an active part and concurrent download cannot unlink it',
    () async {
      final body = StreamController<List<int>>();
      final updater = ApkUpdater(client: _StreamClient(body.stream));
      addTearDown(updater.close);
      final progress = Completer<void>();
      final pending = updater.download(
        url,
        destination: directory,
        onProgress: (_, _) {
          if (!progress.isCompleted) progress.complete();
        },
      );
      body.add(apkBytes);
      await progress.future;
      final part = directory.listSync().whereType<File>().single;
      await part.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await ApkUpdater.discardDownloadedPackages(directory: directory);
      expect(await part.exists(), isTrue);
      final other = ApkUpdater(
        client: MockClient((_) async => http.Response.bytes(apkBytes, 200)),
      );
      addTearDown(other.close);
      await expectLater(
        other.download(url, destination: directory),
        throwsA(isA<ApkUpdateException>()),
      );
      expect(await part.exists(), isTrue);
      await body.close();
      expect(await (await pending).readAsBytes(), apkBytes);
      expect(directory.listSync().length, 1);
    },
  );

  test(
    'cancel while waiting for headers releases lock without accepting late bytes',
    () async {
      final response = Completer<http.StreamedResponse>();
      final updater = ApkUpdater(client: _PendingClient(response.future));
      final pending = updater.download(url, destination: directory);
      final assertion = expectLater(
        pending,
        throwsA(isA<ApkUpdateCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      updater.close();
      await assertion;
      response.complete(http.StreamedResponse(Stream.value(apkBytes), 200));
      await Future<void>.delayed(Duration.zero);
      expect(directory.listSync(), isEmpty);
    },
  );
  test(
    'cold and foreground sweeps retain a completed APK even after a long wait',
    () async {
      final apk = File('${directory.path}/update-123.apk')
        ..writeAsBytesSync(apkBytes);
      await apk.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      // No in-memory install registration: this represents a cold process with
      // an installer still holding the previous process's content URI.
      await ApkUpdater.discardDownloadedPackages(directory: directory);
      await ApkUpdater.discardDownloadedPackages(
        directory: directory,
        olderThan: ApkUpdater.downloadedPackageGrace,
      );
      expect(await apk.readAsBytes(), apkBytes);
      expect(directory.listSync().length, 1);
    },
  );
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.body, {this.contentLength});
  final Stream<List<int>> body;
  final int? contentLength;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200, contentLength: contentLength);
}

class _PendingClient extends http.BaseClient {
  _PendingClient(this.response);
  final Future<http.StreamedResponse> response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response;
}
