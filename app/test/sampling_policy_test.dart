import 'package:cycling_app/core/location/sampling_policy.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// When the app asks for fixes less often (spec §32).
///
/// The interesting cases are all about *not* changing: the cost of sampling
/// slowly is noticing movement late, and the cost of changing is a platform
/// re-subscription. Both are paid in city traffic, at every red light, unless
/// the rule has hysteresis and a dwell.
void main() {
  final start = DateTime.utc(2026, 9, 25, 6);

  SamplingPolicy policy({GpsAccuracyMode chosen = GpsAccuracyMode.high}) =>
      SamplingPolicy(chosen: chosen);

  test('a rider who does not move is sampled less often, at the same accuracy',
      () {
    final p = policy();

    expect(p.update(speedMps: 0, at: start), isFalse);
    expect(p.request.accuracy, GpsAccuracyMode.high);
    expect(p.request.interval, const Duration(seconds: 1));

    // Half a minute of stillness.
    expect(p.update(speedMps: 0, at: start.add(const Duration(seconds: 31))),
        isTrue);
    expect(p.request.accuracy, GpsAccuracyMode.high);
    expect(
      p.request.interval,
      SamplingPolicy.relaxedInterval,
      reason: '停车只拉长间隔。降到均衡功耗会让卫星芯片休眠，红灯处定位就断了',
    );
  });

  test('movement is noticed quickly — the upgrade does not wait', () {
    final p = policy();
    p.update(speedMps: 0, at: start);
    p.update(speedMps: 0, at: start.add(const Duration(seconds: 31)));

    final movingAt = start.add(const Duration(minutes: 2));
    expect(p.update(speedMps: 5, at: movingAt), isFalse);
    expect(
      p.update(speedMps: 5, at: movingAt.add(const Duration(seconds: 5))),
      isTrue,
      reason: '起步只等 5 秒，不能等一分钟的静默期',
    );
    expect(p.request.accuracy, GpsAccuracyMode.high);
    expect(p.request.interval, const Duration(seconds: 1));
  });

  test('a red light does not thrash the subscription', () {
    final p = policy();

    // Stopped for long enough to relax.
    p.update(speedMps: 0, at: start);
    p.update(speedMps: 0, at: start.add(const Duration(seconds: 31)));
    expect(p.isRelaxed, isTrue);

    // Moving again: back to the rider's profile.
    p.update(speedMps: 5, at: start.add(const Duration(seconds: 40)));
    expect(p.update(speedMps: 5, at: start.add(const Duration(seconds: 45))),
        isTrue);

    // Another stop five seconds later, maturing 36 s after the change: still
    // inside the dwell, so no second round trip.
    final secondStop = start.add(const Duration(seconds: 50));
    p.update(speedMps: 0, at: secondStop);
    expect(
      p.update(speedMps: 0, at: secondStop.add(const Duration(seconds: 31))),
      isFalse,
      reason: '一分钟内不再次改变',
    );
    expect(p.request.interval, const Duration(seconds: 1));

    // Past the dwell, with a fresh stop after riding away, it is allowed
    // again.
    p.update(speedMps: 5, at: start.add(const Duration(minutes: 1)));
    final laterStop = start.add(const Duration(minutes: 3));
    p.update(speedMps: 0, at: laterStop);
    expect(
      p.update(speedMps: 0, at: laterStop.add(const Duration(seconds: 31))),
      isTrue,
    );
    expect(p.isRelaxed, isTrue);
    expect(p.request.interval, SamplingPolicy.relaxedInterval);
  });

  test('a slow crawl decides nothing', () {
    // Between the two thresholds: not stopped, not moving. Treating this as
    // either would flip the answer while the rider is walking the bike.
    final p = policy();
    for (var second = 0; second <= 120; second += 5) {
      final changed = p.update(
        speedMps: 2.5 / 3.6,
        at: start.add(Duration(seconds: second)),
      );
      expect(changed, isFalse);
    }
    expect(p.request.accuracy, GpsAccuracyMode.high);
    expect(p.request.interval, const Duration(seconds: 1));
  });

  test('the profile never goes better than what the rider chose', () {
    final p = policy(chosen: GpsAccuracyMode.batterySaver);

    // Moving for a long time does not upgrade a rider who asked for frugal.
    for (var second = 0; second <= 300; second += 5) {
      p.update(speedMps: 6, at: start.add(Duration(seconds: second)));
    }
    expect(p.request.accuracy, GpsAccuracyMode.batterySaver);
    expect(p.request.interval, const Duration(seconds: 5));

    // And a rider on 省电 who stops stays there — already at the slow
    // interval, so relaxing must not pretend the request changed.
    p.update(speedMps: 0, at: start.add(const Duration(minutes: 10)));
    p.update(speedMps: 0, at: start.add(const Duration(minutes: 11)));
    expect(p.request.accuracy, GpsAccuracyMode.batterySaver);
    expect(p.request.interval, const Duration(seconds: 5));
  });

  test('a settings change mid-ride takes effect immediately', () {
    final p = policy();
    p.update(speedMps: 0, at: start);
    p.update(speedMps: 0, at: start.add(const Duration(seconds: 31)));
    expect(p.isRelaxed, isTrue);

    p.setChosen(GpsAccuracyMode.balanced);

    expect(p.request.accuracy, GpsAccuracyMode.balanced);
    expect(p.request.interval, const Duration(seconds: 2));
    expect(p.isRelaxed, isFalse);
    expect(p.chosen, GpsAccuracyMode.balanced);
  });
}
