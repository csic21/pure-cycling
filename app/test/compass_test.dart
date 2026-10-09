import 'dart:async';
import 'dart:math' as math;

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/location/compass_source.dart';
import 'package:cycling_app/core/location/gps_filter.dart';
import 'package:cycling_app/core/location/location_fix.dart';
import 'package:cycling_app/features/ride/data/ride_recorder.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride_engine.dart';
import 'package:cycling_app/features/settings/domain/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

import 'support/test_harness.dart';

/// A compass that answers from a list the test controls.
class FakeCompassSource implements CompassSource {
  FakeCompassSource({this.available = true});

  final bool available;
  final _controller = StreamController<CompassSample>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<CompassSample> samples() {
    if (!available) {
      return Stream<CompassSample>.error(
        StateError('no compass on this device'),
      );
    }
    return _controller.stream;
  }

  void emit(double degrees, {double? accuracy}) {
    if (_controller.isClosed) return;
    _controller.add(
      CompassSample(
        headingDegrees: degrees,
        timestamp: DateTime.now().toUtc(),
        accuracyDegrees: accuracy,
      ),
    );
  }

  Future<void> dispose() => _controller.close();
}

void main() {
  /// A fix [east] metres and [north] metres from the origin.
  ///
  /// At this latitude a degree of longitude is about 76% of a degree of
  /// latitude, which the conversion below accounts for — otherwise an
  /// "east" fix would come out slightly north of due east and the bearings
  /// below would be a degree or two off.
  LocationFix fixAt(
    DateTime at, {
    double east = 0,
    double north = 0,
    double? heading,
    double? speed,
    double? headingAccuracy,
    double accuracy = 4,
  }) => LocationFix(
    latitude: 39.9 + north / 111132.0,
    longitude: 116.4 + east / (111320.0 * math.cos(39.9 * math.pi / 180.0)),
    timestamp: at,
    accuracy: accuracy,
    heading: heading,
    speed: speed,
    headingAccuracy: headingAccuracy,
  );

  /// Drives [count] fixes that do not move — one a second, from the position
  /// given by [east]/[north] — the parked-at-a-junction case the compass
  /// exists for.
  ///
  /// The position has to be supplied rather than defaulted to the origin:
  /// a fix that jumped back to the origin really did move, and the filter
  /// would derive a course from it, which is a very different test.
  ///
  /// Emits [compassDegrees] before each fix unless it is null, which is how
  /// the no-compass case is driven. Returns the bearing after the last fix.
  double? holdStill(
    GpsFilter filter,
    DateTime from, {
    double? compassDegrees,
    double east = 0,
    double north = 0,
    int count = 12,
  }) {
    double? bearing;
    for (var i = 1; i <= count; i++) {
      final at = from.add(Duration(seconds: i));
      if (compassDegrees != null) {
        filter.onCompassHeading(compassDegrees, at: at);
      }
      bearing = filter.process(fixAt(at, east: east, north: north)).bearing;
    }
    return bearing;
  }

  group('the fusion', () {
    test('without compass a stopped course expires instead of freezing', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // A fix that moves far enough to derive a course, then a long standstill
      // with nothing to derive one from. The last course expires.
      filter.process(fixAt(t0));
      final moved = filter.process(
        fixAt(t0.add(const Duration(seconds: 1)), east: 10),
      );
      expect(moved.bearing, closeTo(90, 0.5), reason: '正东应当是 90°');

      final still = holdStill(
        filter,
        t0.add(const Duration(seconds: 1)),
        east: 10,
      );
      expect(still, isNull, reason: '停车后没有可信方向时显示定位圆点，不能永久保留旧箭头');
    });

    test('a compass gives a real direction while the bike is stopped', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // Moving east (course 90°) while the compass reads 30°: the phone is
      // mounted 60° off the bike, which is exactly the constant offset the
      // anchor is supposed to absorb.
      filter.onCompassHeading(30, at: t0);
      filter.process(fixAt(t0));
      final moved = filter.process(
        fixAt(t0.add(const Duration(seconds: 1)), east: 10),
      );
      expect(moved.bearing, closeTo(90, 0.5));

      // Parked. The receiver has no course to give; the compass does.
      final still = holdStill(
        filter,
        t0.add(const Duration(seconds: 1)),
        compassDegrees: 45,
        east: 10,
      );
      expect(still, closeTo(105, 1.5), reason: '指南针 45° + 锚点 60° = 105°');
    });

    test('a compass that disagrees with a live GPS course is ignored', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      filter.process(fixAt(t0));
      filter.onCompassHeading(300, at: t0.add(const Duration(seconds: 1)));

      final moved = filter.process(
        fixAt(t0.add(const Duration(seconds: 1)), east: 10),
      );
      expect(
        moved.bearing,
        closeTo(90, 0.5),
        reason: '在动的时候 GPS 航向才是行进方向，指南针只能填空',
      );
    });

    test('a compass that has gone quiet stops standing in', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      filter.onCompassHeading(30, at: t0);
      filter.process(fixAt(t0));
      filter.process(fixAt(t0.add(const Duration(seconds: 1)), east: 10));

      // Ten seconds later with no further readings: the compass is gone, and
      // the reading from ten seconds ago must not be presented as current.
      final at = t0.add(const Duration(seconds: 11));
      final still = filter.process(fixAt(at, east: 10)).bearing;
      expect(still, isNull, reason: '指南针和 GPS 都已过期，不能继续冒充方向');
    });

    test('a compass the phone cannot stand behind is ignored', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // Beside something magnetic: the platform says the reading could be 90°
      // out, which makes it worth less than the stale course it would replace.
      filter.onCompassHeading(30, at: t0, accuracyDegrees: 90);
      filter.process(fixAt(t0));
      filter.process(fixAt(t0.add(const Duration(seconds: 1)), east: 10));

      final still = holdStill(
        filter,
        t0.add(const Duration(seconds: 1)),
        compassDegrees: 45,
        east: 10,
      );
      expect(still, isNull);
    });

    test('an explicitly invalid accuracy cannot calibrate a compass', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // A platform explicitly reporting invalid heading accuracy is rejected.
      filter.onCompassHeading(30, at: t0, accuracyDegrees: -1);
      filter.process(fixAt(t0));
      filter.process(fixAt(t0.add(const Duration(seconds: 1)), east: 10));

      final still = holdStill(
        filter,
        t0.add(const Duration(seconds: 1)),
        compassDegrees: 45,
        east: 10,
      );
      expect(still, isNull, reason: '无效精度不能校准指南针');
    });

    test('a heading crossing north does not swing the long way round', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // Ten metres away on a course of 350°: mostly north, a little west.
      const course = 350.0;
      final north = 10 * math.cos(course * math.pi / 180);
      final east = 10 * math.sin(course * math.pi / 180);

      // Compass reads 10° while the course is 350°: the anchor is 340°, so a
      // compass reading of 15° is a heading of 355°.
      filter.onCompassHeading(10, at: t0);
      filter.process(fixAt(t0));
      final moved = filter.process(
        fixAt(t0.add(const Duration(seconds: 1)), east: east, north: north),
      );
      expect(moved.bearing, closeTo(350, 0.5));

      final still = holdStill(
        filter,
        t0.add(const Duration(seconds: 1)),
        compassDegrees: 15,
        east: east,
        north: north,
        count: 1,
      );
      // Smoothed a third of the way from 350° to 355° — the short way. The
      // long way would land near 250°.
      expect(still, closeTo(351.5, 0.5), reason: '方位角是环形的，插值不能绕远路');
    });

    test('no anchor is invented before a GPS course exists', () {
      final filter = GpsFilter();
      final t0 = DateTime.utc(2026, 9, 28, 6);

      // A ride started at a standstill: compass readings arrive, but nothing
      // has said which way the bike is pointing in the world the map uses.
      filter.onCompassHeading(120, at: t0);
      final first = filter.process(fixAt(t0)).bearing;
      expect(first, isNull, reason: '没有 GPS 航向可锚定时，不能凭空造一个方向出来');
    });
  });

  group('travel direction regressions', () {
    final t0 = DateTime.utc(2026, 10, 9);

    test('first stationary platform heading is not travel direction', () {
      final filter = GpsFilter();
      expect(filter.process(fixAt(t0, heading: 270, speed: 0)).bearing, isNull);
      for (var i = 1; i < 12; i++) {
        expect(
          filter
              .process(
                fixAt(
                  t0.add(Duration(seconds: i)),
                  east: i.isEven ? 1 : -1,
                  heading: i * 25.0,
                  speed: 0.2,
                ),
              )
              .bearing,
          isNull,
        );
      }
    });

    test('slow travel accumulates a reliable baseline across fixes', () {
      final filter = GpsFilter();
      filter.process(fixAt(t0));
      for (var i = 1; i < 4; i++) {
        expect(
          filter
              .process(fixAt(t0.add(Duration(seconds: i)), east: i * 1.5))
              .bearing,
          isNull,
        );
      }
      final result = filter.process(
        fixAt(t0.add(const Duration(seconds: 5)), east: 7.5),
      );
      expect(result.bearing, closeTo(90, 0.5));
    });

    test('reported course requires speed and heading accuracy', () {
      final reliable = GpsFilter();
      expect(
        reliable
            .process(fixAt(t0, heading: 90, speed: 5, headingAccuracy: 5))
            .bearing,
        90,
      );
      for (final heading in [double.nan, double.infinity, -1.0, 360.0]) {
        expect(
          GpsFilter().process(fixAt(t0, heading: heading, speed: 5)).bearing,
          isNull,
        );
      }
      expect(
        GpsFilter()
            .process(fixAt(t0, heading: 90, speed: 5, headingAccuracy: 80))
            .bearing,
        isNull,
      );
    });

    test('a rejected teleport cannot become a later travel baseline', () {
      final filter = GpsFilter();
      filter.process(fixAt(t0));
      filter.process(fixAt(t0.add(const Duration(seconds: 1)), east: 1000));
      expect(
        filter
            .process(fixAt(t0.add(const Duration(seconds: 2)), east: 1000))
            .bearing,
        isNull,
      );
    });

    test('poor-accuracy position jitter cannot derive a course', () {
      final filter = GpsFilter();
      filter.process(fixAt(t0, accuracy: 25));
      expect(
        filter
            .process(
              fixAt(t0.add(const Duration(seconds: 1)), east: 10, accuracy: 25),
            )
            .bearing,
        isNull,
      );
    });

    for (final frame in [1, 2, 3]) {
      test('display frame 0 to $frame discards old mount calibration', () {
        final filter = GpsFilter();
        filter.onCompassHeading(30, at: t0);
        filter.process(fixAt(t0, heading: 90, speed: 5));
        filter.process(fixAt(t0.add(const Duration(seconds: 1)), speed: 0));
        filter.onCompassHeading(
          120,
          at: t0.add(const Duration(seconds: 2)),
          orientationQuarterTurns: frame,
        );
        expect(
          filter.advanceBearingFromCompass(t0.add(const Duration(seconds: 2))),
          isNull,
        );
        final movingAt = t0.add(const Duration(seconds: 3));
        filter.onCompassHeading(
          120,
          at: movingAt,
          orientationQuarterTurns: frame,
        );
        expect(
          filter
              .process(fixAt(movingAt, east: 10, heading: 90, speed: 5))
              .bearing,
          90,
        );
        filter.process(
          fixAt(t0.add(const Duration(seconds: 4)), east: 10, speed: 0),
        );
        expect(
          filter.advanceBearingFromCompass(t0.add(const Duration(seconds: 4))),
          90,
        );
      });
    }

    test('live GPS wins even when display frame changes', () {
      final filter = GpsFilter();
      filter.onCompassHeading(10, at: t0);
      filter.process(fixAt(t0, heading: 90, speed: 5));
      filter.onCompassHeading(
        270,
        at: t0.add(const Duration(seconds: 1)),
        orientationQuarterTurns: 1,
      );
      expect(
        filter.advanceBearingFromCompass(t0.add(const Duration(seconds: 1))),
        90,
      );
    });

    test('compass can take over after GPS dropout then expires itself', () {
      final filter = GpsFilter();
      filter.onCompassHeading(30, at: t0);
      filter.process(fixAt(t0, heading: 90, speed: 5));
      final later = t0.add(const Duration(seconds: 9));
      filter.onCompassHeading(45, at: later);
      expect(filter.advanceBearingFromCompass(later), 105);
      expect(
        filter.currentBearing(later.add(const Duration(seconds: 9))),
        isNull,
      );
      filter.reset();
      filter.onCompassHeading(45, at: later.add(const Duration(seconds: 10)));
      expect(
        filter.advanceBearingFromCompass(
          later.add(const Duration(seconds: 10)),
        ),
        isNull,
      );
    });

    test('display frame change after GPS dropout clears compass bearing', () {
      final filter = GpsFilter();
      filter.onCompassHeading(30, at: t0);
      filter.process(fixAt(t0, heading: 90, speed: 5));
      final later = t0.add(const Duration(seconds: 9));
      filter.onCompassHeading(45, at: later);
      expect(filter.advanceBearingFromCompass(later), 105);
      final rotatedAt = later.add(const Duration(seconds: 1));
      filter.onCompassHeading(135, at: rotatedAt, orientationQuarterTurns: 1);
      expect(filter.advanceBearingFromCompass(rotatedAt), isNull);
    });

    test('preparation expires direction without starting the ride clock', () {
      fakeAsync((clock) {
        final engine = RideEngine(now: () => t0.add(clock.elapsed));
        unawaited(engine.start());
        engine.onLocation(fixAt(t0, heading: 90, speed: 5));
        expect(engine.state.bearing, 90);
        clock.elapse(const Duration(seconds: 9));
        expect(engine.state.bearing, isNull);
        expect(engine.state.status, RideStatus.preparing);
        expect(engine.state.stats.elapsed, Duration.zero);
        unawaited(engine.dispose());
      });
    });

    test(
      'engine clock expires heading with no sensor events; stop clears it',
      () {
        fakeAsync((clock) {
          final engine = RideEngine(now: () => t0.add(clock.elapsed));
          engine.start();
          engine.beginRecording();
          engine.onLocation(fixAt(t0, heading: 90, speed: 5));
          expect(engine.state.bearing, 90);
          clock.elapse(const Duration(seconds: 9));
          expect(engine.state.bearing, isNull);
          engine.onLocation(
            fixAt(t0.add(clock.elapsed), east: 20, heading: 90, speed: 5),
          );
          expect(engine.state.bearing, 90);
          unawaited(engine.stop());
          expect(engine.state.bearing, isNull);
          engine.cancel();
          engine.start();
          expect(engine.state.bearing, isNull);
          unawaited(engine.dispose());
        });
      },
    );
  });

  group('the engine', () {
    /// A started engine on a clock the test controls.
    void withRidingEngine(
      void Function(RideEngine engine, void Function(Duration) advance) body,
    ) {
      var now = DateTime.utc(2026, 9, 28, 6);
      final engine = RideEngine(now: () => now);
      engine.start();
      engine.beginRecording();
      body(engine, (d) => now = now.add(d));
      unawaited(engine.dispose());
    }

    test('small compass turns accumulate against the published direction', () {
      withRidingEngine((engine, advance) {
        final at = DateTime.utc(2026, 9, 28, 6);
        engine.onCompassHeading(30, at: at);
        engine.onLocation(fixAt(at, heading: 90, speed: 5));
        advance(const Duration(seconds: 1));
        engine.onLocation(fixAt(at.add(const Duration(seconds: 1)), speed: 0));
        for (var i = 1; i <= 15; i++) {
          engine.onCompassHeading(
            30.0 + i,
            at: at.add(Duration(milliseconds: 1000 + i * 20)),
          );
        }
        expect(engine.state.bearing, greaterThan(94));
      });
    });

    test('a compass reading moves the bearing with no fix behind it', () {
      withRidingEngine((engine, advance) {
        // The compass is already reporting when the ride starts — both streams
        // are subscribed together and a course needs a metre or two of travel,
        // so this is the order a real ride sees.
        engine.onCompassHeading(30, at: DateTime.utc(2026, 9, 28, 6));

        // Establish a course: due east. The compass reading now sets the
        // anchor at 90° − 30° = 60°.
        engine.onLocation(fixAt(DateTime.utc(2026, 9, 28, 6)));
        advance(const Duration(seconds: 1));
        engine.onLocation(fixAt(DateTime.utc(2026, 9, 28, 6, 0, 1), east: 10));
        expect(engine.state.bearing, closeTo(90, 0.5));

        // Stopped. The next fix carries no course — `hasBearing()` is false —
        // and that is what hands the direction over to the compass.
        advance(const Duration(seconds: 1));
        engine.onLocation(fixAt(DateTime.utc(2026, 9, 28, 6, 0, 2), east: 10));
        expect(
          engine.state.bearing,
          closeTo(90, 0.5),
          reason: '指南针 30° + 锚点 60° 与刚才的航向一致，方向不该跳',
        );

        // Now the rider turns the bars at the junction. No new fix is coming
        // for seconds, and when it does the receiver will have no course to
        // give — so the compass is the only thing that can move this.
        engine.onCompassHeading(130, at: DateTime.utc(2026, 9, 28, 6, 0, 3));
        expect(
          engine.state.bearing,
          closeTo(120, 1),
          reason: '指南针 130° + 锚点 60° = 190°，从 90° 平滑过去约 120°',
        );
      });
    });
  });

  group('the recorder wiring', () {
    late AppDatabase database;

    setUp(() => database = openTestDatabase());
    tearDown(() => database.close());

    test('compass readings reach the ride state', () async {
      final location = FakeLocationService();
      final compass = FakeCompassSource();
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        compass: compass,
      );

      await recorder.startRide(const AppSettings());
      await recorder.beginRecording();

      // The compass is already reporting when the ride starts, and the two
      // fixes heading north establish the course it gets anchored to.
      compass.emit(0);
      final t0 = DateTime.now().toUtc();
      location.emitRide(count: 3, speedMps: 5, start: t0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final course = recorder.state.bearing;
      expect(course, isNotNull);
      expect(course, closeTo(0, 1), reason: 'emitRide 是向北走的');

      // A stationary fix: the platform reports no bearing while stopped, which
      // is what hands the direction over to the compass.
      final stoppedAt = t0.add(const Duration(seconds: 4));
      location.emit(
        LocationFix(
          latitude: 39.9042 + 15 / 111132.0,
          longitude: 116.4074,
          timestamp: stoppedAt,
          accuracy: 4,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The rider turns the bars 40° clockwise. The compass is anchored to the
      // north-ish course, so the heading should start following it.
      compass.emit(40);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        recorder.state.bearing,
        closeTo(40 * 0.3, 2),
        reason: '指南针要进入 RideState，而不是只到引擎就停了',
      );

      await recorder.dispose();
      await compass.dispose();
      await location.dispose();
    });

    test('a device with no compass is not an error', () async {
      final location = FakeLocationService();
      final compass = FakeCompassSource(available: false);
      final recorder = RideRecorder(
        db: database,
        repository: RideRepository(database),
        locationService: location,
        compass: compass,
      );

      expect(await recorder.startRide(const AppSettings()), isTrue);
      await recorder.beginRecording();
      location.emitRide(count: 20, speedMps: 5);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final ride = await recorder.stopRide();
      expect(ride, isNotNull);
      expect(ride!.stats.distanceMeters, greaterThan(0));

      await recorder.dispose();
      await compass.dispose();
      await location.dispose();
    });
  });
}
