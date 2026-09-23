import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// Generates a UUIDv7 — time-ordered, and a valid Postgres `uuid`.
///
/// The cloud schema declares `id uuid primary key` (spec §19), so local IDs
/// have to *be* UUIDs; a locally invented format would need translating on the
/// way up and would break the moment two devices referred to the same record.
///
/// v7 rather than v4 because the first 48 bits are a millisecond timestamp.
/// That makes IDs sort in creation order, which means:
///
/// * The sync merge can break a timestamp tie deterministically without a
///   round trip.
/// * Inserts into the Postgres primary key index append rather than scatter,
///   which matters once a rider has thousands of rides.
///
/// It is also collision-safe across devices offline, which v4 is and a
/// timestamp-plus-counter scheme is not.
String generateId() => _uuid.v7();

/// Whether a string is a well-formed UUID.
///
/// Used to keep a malformed id (a legacy row, a hand-edited database) from
/// producing a 500 from Postgres instead of a row-level error the client can
/// report.
bool isUuid(String value) {
  if (value.length != 36) return false;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final isHyphenPosition = i == 8 || i == 13 || i == 18 || i == 23;
    if (isHyphenPosition) {
      if (c != 0x2D) return false;
      continue;
    }
    final isHex = (c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x66) ||
        (c >= 0x41 && c <= 0x46);
    if (!isHex) return false;
  }
  return true;
}
