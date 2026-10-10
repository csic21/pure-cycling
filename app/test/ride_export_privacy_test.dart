import 'dart:async';
import 'dart:io';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/core/gpx/gpx_codec.dart';
import 'package:cycling_app/core/utils/geo.dart';
import 'package:cycling_app/features/ride/data/ride_repository.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Directory temp;
  late RideRepository repository;
  final started = DateTime.utc(2026, 1, 1, 8);
  final ride = Ride(id: 'synthetic-ride', startedAt: started, name: 'private',
    notes: 'private note', startPoint: const GeoPoint(31, 121), endPoint: const GeoPoint(32, 122));
  final trace = [
    TrackPoint(rideId: ride.id, sequence: 1, timestamp: started, lat: 31, lng: 121),
    TrackPoint(rideId: ride.id, sequence: 2, timestamp: started.add(const Duration(seconds: 1)), lat: 32, lng: 122),
  ];
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    temp = await Directory.systemTemp.createTemp('cycling-export-privacy-');
    repository = RideRepository(db, documentsDirectory: () async => temp);
    await repository.saveFinishedRide(ride, unflushed: trace, writeExport: false);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  test('delete scrubs coordinates and removes owned/renamed exports only', () async {
    final gpx = await repository.exportGpx(ride);
    final fit = await repository.exportFit(ride);
    final renamed = await repository.exportGpx(ride.copyWith(name: 'renamed'));
    final arbitrary = File('${temp.path}/chosen-by-user.gpx');
    await arbitrary.writeAsString(GpxCodec.encode(ride, trace));
    final unrelated = File('${temp.path}/exports/unrelated.gpx');
    await unrelated.writeAsString('<gpx creator="Other"><time>2026-01-01T08:00:00Z</time></gpx>');
    final legacy = File('${temp.path}/exports/old-name.gpx');
    await legacy.writeAsString(GpxCodec.encode(ride, trace));
    await repository.deleteRide(ride.id);
    final deleted = (await repository.getRide(ride.id))!;
    expect(deleted.isDeleted, isTrue);
    expect(deleted.startPoint, isNull);
    expect(deleted.endPoint, isNull);
    expect(deleted.routeGeometryWkt, isNull);
    expect(deleted.name, isNull);
    expect(deleted.notes, isNull);
    expect(await repository.trackPointCount(ride.id), 0);
    for (final file in [gpx, fit, renamed, legacy]) {
      expect(await file.exists(), isFalse);
    }
    expect(await arbitrary.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    await expectLater(repository.writeGpxFile(ride, trace), throwsStateError);
  });

  for (final remote in [false, true]) {
    test('deletion fences a delayed export writer (remote: $remote)', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var first = true;
      final writer = RideRepository(db, documentsDirectory: () async {
        if (first) { first = false; entered.complete(); await release.future; }
        return temp;
      });
      final writing = writer.writeGpxFile(ride, trace);
      final rejected = expectLater(writing, throwsStateError);
      await entered.future;
      final deleting = remote ? repository.applyRemoteDelete(ride.id) : repository.deleteRide(ride.id);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await rejected;
      await deleting;
      final files = await temp.list(recursive: true).where((f) => f is File).toList();
      expect(files, isEmpty, reason: 'a late background writer cannot resurrect deleted coordinates');
    });
  }
}
