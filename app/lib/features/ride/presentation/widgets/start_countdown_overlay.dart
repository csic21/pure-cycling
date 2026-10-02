import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme.dart';
import '../../../../features/settings/domain/app_settings.dart';
import '../../domain/ride_engine.dart';

/// The pre-ride countdown (spec §4).
///
/// Two jobs, and the second one is the important one:
///
/// * Give the rider a moment to get both hands on the bars before recording
///   starts, so the first few metres are not recorded in a pocket.
/// * **Show the GPS state while they wait.** The countdown is dead time
///   otherwise, and it is exactly the window in which a fix is being acquired.
///   A rider who sees ±8m before starting knows their whole ride will be
///   accurate; one who sees ±120m learns to wait, without the app having to
///   block them.
///
/// The rider can always skip. Spec §4 is explicit that a weak signal warns but
/// never prevents starting.
class StartCountdownOverlay extends StatefulWidget {
  const StartCountdownOverlay({
    super.key,
    required this.ride,
    required this.settings,
    required this.onFinished,
  });

  final RideState ride;
  final AppSettings settings;
  final VoidCallback onFinished;

  @override
  State<StartCountdownOverlay> createState() => _StartCountdownOverlayState();
}

class _StartCountdownOverlayState extends State<StartCountdownOverlay> {
  Timer? _timer;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _remaining = widget.settings.startCountdown.seconds;
    _tick();
  }

  @override
  void didUpdateWidget(StartCountdownOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Cancel a previous run if the widget is reused across rides.
    if (oldWidget.ride.rideId != widget.ride.rideId) {
      _remaining = widget.settings.startCountdown.seconds;
      _timer?.cancel();
      _tick();
    }
  }

  void _tick() {
    if (_remaining <= 0) {
      // Zero means the countdown is off, but the first fix still deserves a
      // moment — beginning immediately would start the clock before the
      // receiver has settled.
      _timer = Timer(const Duration(milliseconds: 600), _finish);
      return;
    }

    setState(() => _remaining);
    _timer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      _remaining--;
      if (_remaining > 0) {
        setState(() {});
        _tick();
      } else {
        _finish();
      }
    });
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    if (mounted) widget.onFinished();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accuracy = widget.ride.gpsAccuracyMeters;
    final hasFix = widget.ride.lastPoint != null;

    return ColoredBox(
      // Opaque, so the dashboard behind it does not compete for attention
      // while the rider is settling in.
      color: AppColors.background,
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _GpsReadiness(
              accuracy: accuracy,
              hasFix: hasFix,
              satellitesUsed: widget.ride.satellitesUsed,
              cn0AverageDbHz: widget.ride.cn0AverageDbHz,
            ),
            const Spacer(),

            if (_remaining > 0)
              Text(
                '$_remaining',
                style: AppText.hero(140),
              )
            else
              const SizedBox(
                width: 54,
                height: 54,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),

            const SizedBox(height: 16),
            const Text(
              '准备开始',
              style: AppText.label,
            ),
            const Spacer(),

            TextButton(
              onPressed: _finish,
              child: const Text('立即开始'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// The GPS quality readout during the countdown (spec §4).
class _GpsReadiness extends StatelessWidget {
  const _GpsReadiness({
    required this.accuracy,
    required this.hasFix,
    this.satellitesUsed,
    this.cn0AverageDbHz,
  });

  final double accuracy;

  /// Whether any fix has arrived at all, which is different from how good it
  /// is — the first fix is usually poor and improves over about thirty
  /// seconds as the receiver locks onto more satellites.
  final bool hasFix;

  final int? satellitesUsed;
  final double? cn0AverageDbHz;

  ({Color color, String headline}) _classify() {
    if (!hasFix) {
      return (color: AppColors.textSecondary, headline: '正在获取定位…');
    }
    if (accuracy > 50) {
      return (color: AppColors.danger, headline: 'GPS 信号较弱');
    }
    if (accuracy > 20) {
      return (color: AppColors.warning, headline: 'GPS 信号一般');
    }
    return (color: AppColors.success, headline: 'GPS 已就绪');
  }

  @override
  Widget build(BuildContext context) {
    final readiness = _classify();

    return Column(
      children: [
        Icon(
          hasFix ? Icons.gps_fixed : Icons.gps_not_fixed,
          color: readiness.color,
          size: 30,
        ),
        const SizedBox(height: 10),
        Text(
          readiness.headline,
          style: AppText.body.copyWith(color: readiness.color),
        ),
        const SizedBox(height: 4),
        Text(
          hasFix ? '当前精度 ±${accuracy.round()}m' : '请到开阔处等待',
          style: AppText.caption,
        ),
        if (hasFix && _satelliteLine() != null) ...[
          const SizedBox(height: 4),
          Text(_satelliteLine()!, style: AppText.caption),
        ],
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 36),
          child: Text(
            '车把支架朝上固定比放口袋更稳；避开金属壳与强磁吸；'
            '尽量在开阔天空下等 GPS 就绪。',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
        if (hasFix && accuracy > 50) ...[
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '现在开始也可以，但轨迹可能会有偏差。',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
    );
  }

  String? _satelliteLine() {
    final used = satellitesUsed;
    if (used == null || used <= 0) return null;
    final cn0 = cn0AverageDbHz;
    if (cn0 != null && cn0 > 0) {
      return '卫星 $used · CN0 ${cn0.round()} dB-Hz';
    }
    return '卫星 $used';
  }
}
