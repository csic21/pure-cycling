import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../core/utils/units.dart';
import '../../../ride/domain/ride.dart';

/// One ride in a list: date, distance, time, average speed.
///
/// The layout is the spec's list row (§37) — three numbers on one line, no
/// chart, no map, no badge. A rider scanning their history is looking for a
/// distance and a date; everything else is a tap away.
class RideSummaryRow extends StatelessWidget {
  const RideSummaryRow({
    super.key,
    required this.ride,
    required this.formatter,
    this.onTap,
  });

  final Ride ride;
  final UnitFormatter formatter;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final local = ride.startedAt.toLocal();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  UnitFormatter.shortDate(local),
                  style: AppText.label.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ride.displayName(_defaultName(local)),
                    style: AppText.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (ride.syncStatus.isPending)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.cloud_upload_outlined,
                      size: 15,
                      color: AppColors.textTertiary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _Figure(
                  value: formatter.distanceKm(ride.stats.distanceMeters),
                  unit: formatter.system.distanceSuffix,
                  emphasized: true,
                ),
                _Figure(value: UnitFormatter.duration(ride.stats.moving)),
                _Figure(
                  value: formatter.speed(ride.stats.avgSpeedMps),
                  unit: formatter.system.speedSuffix,
                ),
                if (ride.stats.elevationGainMeters > 0)
                  _Figure(
                    value: formatter.elevation(ride.stats.elevationGainMeters),
                    unit: formatter.system.elevationSuffix,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _defaultName(DateTime local) {
    final hour = local.hour;
    final period = hour < 6
        ? '凌晨'
        : hour < 12
            ? '上午'
            : hour < 18
                ? '下午'
                : '晚上';
    return '$period骑行';
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.value,
    this.unit,
    this.emphasized = false,
  });

  final String value;
  final String? unit;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              value,
              style: emphasized
                  ? AppText.value.copyWith(fontSize: 20)
                  : AppText.smallValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: 3),
            Text(unit!, style: AppText.caption.copyWith(fontSize: 10)),
          ],
        ],
      ),
    );
  }
}
