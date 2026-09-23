import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/utils/units.dart';

/// An elevation profile, drawn directly on a canvas.
///
/// Hand-drawn rather than pulled from a charting package: the requirements are
/// narrow — one filled area, a min/max label, no axes, no tooltips, no legend —
/// and a general-purpose chart library would bring a theme system, a dozen
/// gesture handlers and a dependency to do it.
///
/// The chart is deliberately sparse. On an OLED screen at night, a grid of
/// axis lines is glare; what a rider wants from an elevation profile is the
/// *shape* and the two numbers that bound it.
class ElevationChart extends StatelessWidget {
  const ElevationChart({
    super.key,
    required this.samples,
    this.height = 90,
    this.formatter = const UnitFormatter(UnitSystem.metric),
    this.lineColor = AppColors.accent,
    this.fillColor = AppColors.elevationFill,
    this.showBounds = true,
    this.distanceMeters,
  });

  /// Elevation samples in meters, evenly spaced along the route. Even spacing
  /// is the caller's contract — [ElevationChart] does not know or care about
  /// the horizontal axis.
  final List<double> samples;

  final double height;
  final UnitFormatter formatter;
  final Color lineColor;
  final Color fillColor;
  final bool showBounds;

  /// Total horizontal distance, used only for the axis labels.
  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('暂无海拔数据', style: AppText.caption),
        ),
      );
    }

    final minValue = samples.reduce(math.min);
    final maxValue = samples.reduce(math.max);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBounds)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatter.elevationWithUnit(minValue),
                  style: AppText.caption,
                ),
                if (distanceMeters != null)
                  Text(
                    '${formatter.distanceKm(distanceMeters!, decimals: 1)} '
                    '${formatter.system.distanceSuffix}',
                    style: AppText.caption,
                  ),
                Text(
                  formatter.elevationWithUnit(maxValue),
                  style: AppText.caption,
                ),
              ],
            ),
          ),
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _ElevationPainter(
              samples: samples,
              minValue: minValue,
              maxValue: maxValue,
              lineColor: lineColor,
              fillColor: fillColor,
            ),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

class _ElevationPainter extends CustomPainter {
  _ElevationPainter({
    required this.samples,
    required this.minValue,
    required this.maxValue,
    required this.lineColor,
    required this.fillColor,
  });

  final List<double> samples;
  final double minValue;
  final double maxValue;
  final Color lineColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0 || size.height <= 0) return;

    // A profile with almost no relief — a flat canal path — would otherwise
    // be drawn as a violent sawtooth, because 1 m of noise stretched over the
    // full height looks like a mountain. A 20 m floor keeps small variation
    // looking small.
    final range = math.max(maxValue - minValue, 20.0);
    // Centre the profile vertically within the padded range rather than
    // pinning it to the bottom, so a flat route draws a flat line in the
    // middle instead of sitting on the axis.
    final baseline = (minValue + maxValue) / 2;

    const verticalPadding = 6.0;
    final drawHeight = size.height - verticalPadding * 2;
    final dx = size.width / (samples.length - 1);

    double yFor(double value) {
      final normalized = (value - baseline) / range + 0.5;
      return verticalPadding + (1 - normalized.clamp(0.0, 1.0)) * drawHeight;
    }

    final line = Path()..moveTo(0, yFor(samples.first));
    for (var i = 1; i < samples.length; i++) {
      line.lineTo(i * dx, yFor(samples[i]));
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = fillColor,
    );

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = lineColor,
    );
  }

  @override
  bool shouldRepaint(_ElevationPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.minValue != minValue ||
        oldDelegate.maxValue != maxValue ||
        oldDelegate.lineColor != lineColor;
  }
}

/// A compact sparkline for list rows.
class ElevationSparkline extends StatelessWidget {
  const ElevationSparkline({
    super.key,
    required this.samples,
    this.height = 28,
    this.color = AppColors.accent,
  });

  final List<double> samples;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) return SizedBox(height: height);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _ElevationPainter(
          samples: samples,
          minValue: samples.reduce(math.min),
          maxValue: samples.reduce(math.max),
          lineColor: color,
          fillColor: Colors.transparent,
        ),
        size: Size.infinite,
      ),
    );
  }
}
