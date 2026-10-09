import 'package:cycling_app/core/sync/sync_wake_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a single failed item wakes at its persisted backoff expiry', () {
    fakeAsync((time) {
      final start = DateTime.utc(2026);
      var calls = 0;
      final wake = SyncWakeScheduler(
        now: () => start.add(time.elapsed),
        onWake: () => calls++,
      );
      wake.schedule(start.add(const Duration(seconds: 15)));
      time.elapse(const Duration(seconds: 14));
      expect(calls, 0);
      time.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      expect(time.pendingTimers, isEmpty);
      wake.dispose();
    });
  });

  test('new enqueue preempts backoff and repeated notifications coalesce', () {
    fakeAsync((time) {
      final start = DateTime.utc(2026);
      var calls = 0;
      final wake = SyncWakeScheduler(
        now: () => start.add(time.elapsed),
        onWake: () => calls++,
      );
      wake.schedule(start.add(const Duration(hours: 1)));
      for (var i = 0; i < 20; i++) {
        wake.schedule(start);
      }
      expect(time.pendingTimers, hasLength(1));
      time.elapse(Duration.zero);
      expect(calls, 1);
      time.elapse(const Duration(hours: 2));
      expect(calls, 1);
      wake.dispose();
    });
  });

  test('empty queue, disabled lifecycle and disposal cancel stale wakes', () {
    fakeAsync((time) {
      final start = DateTime.utc(2026);
      var calls = 0;
      final wake = SyncWakeScheduler(now: () => start, onWake: () => calls++);
      wake.schedule(start);
      wake.schedule(null);
      time.elapse(const Duration(seconds: 1));
      wake.schedule(start);
      wake.cancel();
      time.elapse(const Duration(seconds: 1));
      wake.schedule(start);
      wake.dispose();
      wake.schedule(start);
      time.elapse(const Duration(hours: 1));
      expect(calls, 0);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('remaining batches have a bounded delay rather than a busy loop', () {
    fakeAsync((time) {
      final start = DateTime.utc(2026);
      var calls = 0;
      final wake = SyncWakeScheduler(now: () => start, onWake: () => calls++);
      wake.schedule(start, minimumDelay: const Duration(seconds: 1));
      time.elapse(Duration.zero);
      expect(calls, 0);
      time.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      wake.dispose();
    });
  });
}
