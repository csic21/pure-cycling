import 'package:cycling_app/core/sync/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cloud GPX paths stay within one exact ride, including epoch uploads',
    () {
      const user = '00000000-0000-4000-8000-000000000001';
      const ride = '00000000-0000-4000-8000-000000000002';
      const epoch = '00000000-0000-4000-8000-000000000003';
      const attempt = '00000000-0000-4000-8000-000000000004';
      bool valid(String path) => SupabaseConfig.isRideGpxPath(path, user, ride);
      expect(valid('rides/$user/$ride/original.gpx'), isTrue);
      expect(valid('rides/$user/$ride/$epoch/$attempt.gpx'), isTrue);
      expect(valid('rides/$user/$ride/../other.gpx'), isFalse);
      expect(valid('rides/other-user/$ride/$epoch/$attempt.gpx'), isFalse);
      expect(valid('rides/$user/other-ride/$epoch/$attempt.gpx'), isFalse);
      expect(valid('rides/$user/$ride/invalid-epoch/$attempt.gpx'), isFalse);
      expect(valid('/device/exports/ride.gpx'), isFalse);
    },
  );
}
