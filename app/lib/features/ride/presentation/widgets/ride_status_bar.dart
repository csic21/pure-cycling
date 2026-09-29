import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../domain/ride_engine.dart';

/// The strip along the top of the ride screen.
///
/// Deliberately thin. Nothing here is a number the rider needs while moving —
/// it is status: is the recording healthy, and is anything wrong. A GPS
/// problem has to be visible without being alarming, because the answer is
/// almost always "keep riding and it will come back".
class RideStatusBar extends StatelessWidget {
  const RideStatusBar({
    super.key,
    required this.ride,
    required this.navigating,
    required this.onClose,
    this.routeName,
    this.batteryPercent,
    this.onToggleMinimal,
    this.isMapMode = false,
  });

  final RideState ride;
  final bool navigating;
  final String? routeName;
  final double? batteryPercent;
  final VoidCallback onClose;

  /// Switches between the minimal and map navigation presentations.
  final VoidCallback? onToggleMinimal;
  final bool isMapMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down, size: 26),
            tooltip: '收起',
          ),

          const SizedBox(width: 2),
          _GpsIndicator(ride: ride),

          if (ride.autoPaused) ...[
            const SizedBox(width: 10),
            const _Chip(
              icon: Icons.pause_circle_outline,
              label: '自动暂停',
              color: AppColors.warning,
            ),
          ],

          if (navigating) ...[
            const SizedBox(width: 10),
            const _Chip(
              icon: Icons.navigation_outlined,
              label: '导航中',
              color: AppColors.accent,
            ),
          ],

          const Spacer(),

          if (ride.sensors.hasAny) ...[
            _SensorChip(ride: ride),
            const SizedBox(width: 8),
          ],

          if (navigating && onToggleMinimal != null)
            IconButton(
              onPressed: onToggleMinimal,
              icon: Icon(
                isMapMode ? Icons.list_alt_outlined : Icons.map_outlined,
                size: 22,
              ),
              tooltip: isMapMode ? '极简导航' : '地图导航',
            ),

          if (batteryPercent != null)
            _BatteryIndicator(percent: batteryPercent!),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// GPS quality, in three states.
///
/// The distinction that matters is *no fix* versus *a fix that is not good
/// enough*. A rider stopped under a bridge needs to know the difference
/// between the app having lost the signal and the app having a bad one — the
/// first is expected and temporary, the second means distance is being
/// withheld.
class _GpsIndicator extends StatelessWidget {
  const _GpsIndicator({required this.ride});

  final RideState ride;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (ride) {
      _ when ride.gpsSignalLost => (
        Icons.gps_off,
        AppColors.danger,
        'GPS 信号丢失',
      ),
      _ when ride.gpsAccuracyMeters <= 0 => (
        Icons.gps_not_fixed,
        AppColors.warning,
        '等待 GPS 定位',
      ),
      _ when ride.gpsPoor => (
        Icons.gps_not_fixed,
        AppColors.warning,
        'GPS 信号较弱 ±${ride.gpsAccuracyMeters.round()}m',
      ),
      _ when ride.gpsAccuracyMeters > 20 => (
        Icons.gps_fixed,
        AppColors.warning,
        'GPS ±${ride.gpsAccuracyMeters.round()}m',
      ),
      _ => (
        Icons.gps_fixed,
        AppColors.success,
        'GPS ±${ride.gpsAccuracyMeters.round()}m',
      ),
    };

    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 4),
          Text(
            ride.gpsSignalLost || ride.gpsAccuracyMeters <= 0
                ? '--'
                : '±${ride.gpsAccuracyMeters.round()}m',
            style: AppText.caption.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _SensorChip extends StatelessWidget {
  const _SensorChip({required this.ride});

  final RideState ride;

  @override
  Widget build(BuildContext context) {
    final sensors = ride.sensors;
    final parts = <String>[
      if (sensors.heartRate != null) '${sensors.heartRate} bpm',
      if (sensors.cadence != null) '${sensors.cadence} rpm',
      if (sensors.power != null) '${sensors.power} W',
      if (sensors.wheelSpeedMps != null)
        '轮速 ${(sensors.wheelSpeedMps! * 3.6).toStringAsFixed(1)} km/h',
    ];

    return Tooltip(
      message: parts.join(' · '),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.bluetooth_connected,
            size: 15,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 4),
          Text(parts.first, style: AppText.caption),
        ],
      ),
    );
  }
}

class _BatteryIndicator extends StatelessWidget {
  const _BatteryIndicator({required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    final color = percent <= 15
        ? AppColors.danger
        : percent <= 30
        ? AppColors.warning
        : AppColors.textTertiary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          percent <= 20 ? Icons.battery_2_bar : Icons.battery_full,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          '${percent.round()}%',
          style: AppText.caption.copyWith(color: color),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 3),
        Text(label, style: AppText.caption.copyWith(color: color)),
      ],
    );
  }
}
