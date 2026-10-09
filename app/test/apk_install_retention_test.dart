import 'dart:async';
import 'dart:io';

import 'package:cycling_app/core/updates/apk_updater.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'installer handoff has no expiry timer and passive sweeps preserve its URI',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'apk-install-retention-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final installed = File('${directory.path}/update-123.apk')
        ..writeAsBytesSync([1]);
      await installed.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      const channel = MethodChannel('app.purecycling/update');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'install');
        expect(call.arguments, {'path': installed.path, 'version': '0.1.18'});
        calls++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      fakeAsync((time) {
        var handedOff = false;
        unawaited(
          ApkUpdater.install(
            installed,
            expectedVersion: '0.1.18',
          ).then((_) => handedOff = true),
        );
        time.flushMicrotasks();
        expect(handedOff, isTrue);
        expect(
          time.nonPeriodicTimerCount,
          0,
          reason:
              'installer ownership must not expire while the app is backgrounded',
        );
        time.elapse(const Duration(hours: 2));
        expect(time.nonPeriodicTimerCount, 0);
      });
      expect(calls, 1);
      // Even a newer legacy leftover must not displace the URI handed to Android.
      final extra = File('${directory.path}/update-456.apk')
        ..writeAsBytesSync([2]);
      await ApkUpdater.discardDownloadedPackages(
        directory: directory,
        olderThan: ApkUpdater.downloadedPackageGrace,
      );
      await ApkUpdater.discardDownloadedPackages(directory: directory);
      expect(await installed.readAsBytes(), [1]);
      expect(await extra.exists(), isFalse);
      expect(directory.listSync().length, 1);

      final repeated = ApkUpdater();
      addTearDown(repeated.close);
      await expectLater(
        repeated.download(
          Uri.parse('https://example.com/update.apk'),
          destination: directory,
        ),
        throwsA(isA<ApkUpdateException>()),
      );
      expect(
        await installed.exists(),
        isTrue,
        reason:
            'the immediate repeated-install cooldown does not retire the first APK',
      );
    },
  );
}
