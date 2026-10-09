import 'dart:async';

import 'package:cycling_app/core/updates/github_release_checker.dart';
import 'package:cycling_app/core/updates/update_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final release = AppRelease(
    version: '0.1.18',
    tag: 'v0.1.18',
    notes: '',
    pageUrl: Uri.parse(
      'https://github.com/csic21/pure-cycling/releases/tag/v0.1.18',
    ),
  );

  for (final transition in ['recording', 'background', 'different route']) {
    test('late automatic response defers after $transition', () async {
      final response = Completer<AppRelease?>();
      var eligible = true;
      var checks = 0;
      var prompts = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (_) {
          checks++;
          return response.future;
        },
      );
      final request = UpdateRequest(
        automatic: true,
        canPresent: () => eligible,
        present: (_) async => prompts++,
        message: (_) => fail('automatic checks stay quiet'),
      );
      final pending = coordinator.check(request);
      eligible = false;
      response.complete(release);
      await pending;
      expect(prompts, 0);
      await coordinator.resumeDeferred();
      expect(prompts, 0);
      eligible = true;
      await coordinator.resumeDeferred();
      expect(prompts, 1);
      expect(checks, 1, reason: 'deferred release bypasses the daily throttle');
      await coordinator.resumeDeferred();
      expect(prompts, 1);
    });
  }

  test(
    'automatic request initially unsafe waits without making a request',
    () async {
      var eligible = false;
      var checks = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (_) async {
          checks++;
          return release;
        },
      );
      await coordinator.check(
        UpdateRequest(
          automatic: true,
          canPresent: () => eligible,
          present: (_) async {},
          message: (_) {},
        ),
      );
      expect(checks, 0);
      eligible = true;
      await coordinator.resumeDeferred();
      expect(checks, 1);
    },
  );

  test(
    'repeated manual taps and second check share the entire update flow',
    () async {
      final response = Completer<AppRelease?>();
      final downloadAndInstall = Completer<void>();
      var checks = 0;
      var prompts = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (_) {
          checks++;
          return response.future;
        },
      );
      final request = UpdateRequest(
        automatic: false,
        canPresent: () => true,
        present: (_) {
          prompts++;
          return downloadAndInstall.future;
        },
        message: (_) {},
      );
      final first = coordinator.check(request);
      expect(identical(first, coordinator.check(request)), isTrue);
      response.complete(release);
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.isBusy, isTrue);
      expect(identical(first, coordinator.check(request)), isTrue);
      expect(checks, 1);
      expect(prompts, 1);
      downloadAndInstall.complete();
      await first;
      expect(coordinator.isBusy, isFalse);
      await coordinator.check(request);
      expect(checks, 2);
    },
  );

  test('manual response cannot present after About is left', () async {
    final response = Completer<AppRelease?>();
    var current = true;
    var prompts = 0;
    final coordinator = AppUpdateCoordinator(
      loadRelease: (_) => response.future,
    );
    final first = coordinator.check(
      UpdateRequest(
        automatic: false,
        canPresent: () => current,
        present: (_) async => prompts++,
        message: (_) => fail('stale toast'),
      ),
    );
    current = false;
    response.complete(release);
    await first;
    current = true;
    await coordinator.resumeDeferred();
    expect(prompts, 0);
  });

  test('dispose suppresses a late response', () async {
    final response = Completer<AppRelease?>();
    final coordinator = AppUpdateCoordinator(
      loadRelease: (_) => response.future,
    );
    final pending = coordinator.check(
      UpdateRequest(
        automatic: true,
        canPresent: () => true,
        present: (_) async => fail('disposed prompt'),
        message: (_) => fail('disposed toast'),
      ),
    );
    coordinator.dispose();
    response.complete(release);
    await pending;
    await coordinator.resumeDeferred();
  });
  test(
    'About tap joins an automatic request without a second prompt or download',
    () async {
      final response = Completer<AppRelease?>();
      var checks = 0;
      var onAbout = false;
      var manualPrompts = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (_) {
          checks++;
          return response.future;
        },
      );
      final automatic = coordinator.check(
        UpdateRequest(
          automatic: true,
          canPresent: () => !onAbout,
          present: (_) async => fail('manual origin must own the prompt'),
          message: (_) {},
        ),
      );
      onAbout = true;
      final manual = coordinator.check(
        UpdateRequest(
          automatic: false,
          canPresent: () => onAbout,
          present: (_) async {
            manualPrompts++;
          },
          message: (_) {},
        ),
      );
      expect(identical(automatic, manual), isTrue);
      response.complete(release);
      await manual;
      expect(checks, 1);
      expect(manualPrompts, 1);
      onAbout = false;
      await coordinator.resumeDeferred();
      expect(manualPrompts, 1);
    },
  );
  test(
    'a manual tap joining a failed automatic check receives its error',
    () async {
      final response = Completer<AppRelease?>();
      final messages = <String>[];
      final coordinator = AppUpdateCoordinator(
        loadRelease: (_) => response.future,
      );
      final pending = coordinator.check(
        UpdateRequest(
          automatic: true,
          canPresent: () => true,
          present: (_) async {},
          message: (_) => fail('automatic toast'),
        ),
      );
      unawaited(
        coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => true,
            present: (_) async {},
            message: messages.add,
          ),
        ),
      );
      response.completeError(
        const ReleaseCheckException('network unavailable'),
      );
      await pending;
      expect(messages, ['network unavailable']);
      expect(coordinator.isBusy, isFalse);
    },
  );
  test(
    'manual tap joining a throttled automatic check performs a fresh check',
    () async {
      final automatic = Completer<AppRelease?>();
      final checks = <bool>[];
      var prompts = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (isAutomatic) {
          checks.add(isAutomatic);
          return isAutomatic ? automatic.future : Future.value(release);
        },
      );
      final pending = coordinator.check(
        UpdateRequest(
          automatic: true,
          canPresent: () => true,
          present: (_) async => fail('manual origin must own this prompt'),
          message: (_) {},
        ),
      );
      unawaited(
        coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => true,
            present: (_) async {
              prompts++;
            },
            message: (_) {},
          ),
        ),
      );
      automatic.complete(null);
      await pending;
      expect(checks, [true, false]);
      expect(prompts, 1);
    },
  );
  for (final foundUpdate in [true, false]) {
    test(
      'reopened About owns a pending manual result (update=$foundUpdate)',
      () async {
        final response = Completer<AppRelease?>();
        var firstMounted = true;
        var checks = 0;
        var newerPrompts = 0;
        final messages = <String>[];
        final coordinator = AppUpdateCoordinator(
          loadRelease: (_) {
            checks++;
            return response.future;
          },
        );
        final pending = coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => firstMounted,
            present: (_) async => fail('obsolete About prompt'),
            message: (_) => fail('obsolete About message'),
          ),
        );
        firstMounted = false;
        final joined = coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => true,
            present: (_) async {
              newerPrompts++;
            },
            message: messages.add,
          ),
        );
        expect(identical(joined, pending), isTrue);
        response.complete(foundUpdate ? release : null);
        await joined;
        expect(checks, 1);
        expect(newerPrompts, foundUpdate ? 1 : 0);
        expect(messages, foundUpdate ? isEmpty : ['已经是最新版本']);
      },
    );
  }

  test(
    'reopened About also owns the automatic-throttle fallback check',
    () async {
      final automatic = Completer<AppRelease?>();
      final manual = Completer<AppRelease?>();
      final checks = <bool>[];
      var originalManualMounted = true;
      var prompts = 0;
      final coordinator = AppUpdateCoordinator(
        loadRelease: (isAutomatic) {
          checks.add(isAutomatic);
          return isAutomatic ? automatic.future : manual.future;
        },
      );
      final pending = coordinator.check(
        UpdateRequest(
          automatic: true,
          canPresent: () => true,
          present: (_) async => fail('obsolete automatic prompt'),
          message: (_) {},
        ),
      );
      unawaited(
        coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => originalManualMounted,
            present: (_) async => fail('obsolete About prompt'),
            message: (_) {},
          ),
        ),
      );
      automatic.complete(null);
      await Future<void>.delayed(Duration.zero);
      originalManualMounted = false;
      unawaited(
        coordinator.check(
          UpdateRequest(
            automatic: false,
            canPresent: () => true,
            present: (_) async {
              prompts++;
            },
            message: (_) {},
          ),
        ),
      );
      manual.complete(release);
      await pending;
      expect(checks, [true, false]);
      expect(prompts, 1);
    },
  );
}
