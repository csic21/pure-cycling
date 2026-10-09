import 'dart:io';

import 'package:cycling_app/core/database/database.dart';
import 'package:cycling_app/features/ride/domain/ride.dart';
import 'package:cycling_app/features/ride/domain/track_point.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'v1 file upgrades without losing points and indexed queries avoid sorting',
    () async {
      final dir = await Directory.systemTemp.createTemp('cycling-migration-');
      final file = File('${dir.path}/v1.sqlite');
      var db = AppDatabase.forTesting(NativeDatabase(file));
      try {
        await db.rideDao.upsertRide(
          Ride(id: 'old-ride', startedAt: DateTime.utc(2026)),
        );
        await db.rideDao.insertTrackPoints([
          for (var i = 3; i > 0; i--)
            TrackPoint(
              rideId: 'old-ride',
              sequence: i,
              timestamp: DateTime.utc(2026).add(Duration(seconds: i)),
              lat: 31,
              lng: 121,
            ),
        ]);
        // v1 has exactly these tables, but no trace index. Persist its old
        // schema version, then reopen through the actual upgrade callback.
        await db.customStatement('DROP INDEX track_points_ride_sequence_idx');
        await db.customStatement('PRAGMA user_version = 1');
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase(file));
        expect(
          (await db.rideDao.getTrackPoints('old-ride')).map((p) => p.sequence),
          [1, 2, 3],
        );
        expect((await db.rideDao.lastTrackPoint('old-ride'))!.sequence, 3);
        expect(await db.rideDao.trackPointCount('old-ride'), 3);
        final version = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.read<int>('user_version'), 2);
        for (final query in [
          "SELECT * FROM track_points WHERE ride_id = 'old-ride' ORDER BY sequence",
          "SELECT * FROM track_points WHERE ride_id = 'old-ride' ORDER BY sequence DESC LIMIT 1",
          "SELECT count(*) FROM track_points WHERE ride_id = 'old-ride'",
        ]) {
          final plan =
              (await db.customSelect('EXPLAIN QUERY PLAN $query').get())
                  .map((row) => row.read<String>('detail'))
                  .join(' ');
          expect(plan, contains('track_points_ride_sequence_idx'));
          expect(plan, isNot(contains('TEMP B-TREE')));
        }
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
