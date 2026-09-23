import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../features/dashboard/domain/dashboard_field.dart';
import '../../core/utils/units.dart';

/// Relative size of a metric on the dashboard.
enum MetricSize {
  /// The single enormous number. At least a fifth of the screen height
  /// (spec §5.1) — this is the value the rider reads at a glance from a
  /// moving bicycle, and everything else on the page is secondary to it.
  hero,

  large,
  medium,
  small,
}

/// One value plus its label and unit.
///
/// The layout is fixed regardless of whether the field currently has data:
/// an unavailable sensor shows `--` in place rather than collapsing, because a
/// dashboard that reflows when a heart rate strap drops out is worse than one
/// that shows a dash.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.field,
    required this.data,
    required this.formatter,
    this.size = MetricSize.medium,
    this.showLabel = true,
    this.alignment = CrossAxisAlignment.center,
  });

  final DashboardField field;
  final DashboardData data;
  final UnitFormatter formatter;
  final MetricSize size;
  final bool showLabel;
  final CrossAxisAlignment alignment;

  bool get _available => field.isAvailable(data);

  @override
  Widget build(BuildContext context) {
    final value = field.format(data, formatter);
    final unit = field.unitLabel(data, formatter);

    final valueStyle = switch (size) {
      MetricSize.hero => AppText.hero(10), // Replaced by the fitted size below.
      MetricSize.large => AppText.bigValue,
      MetricSize.medium => AppText.value,
      MetricSize.small => AppText.smallValue,
    };

    final valueWidget = Text(
      value,
      style: valueStyle.copyWith(
        color: _available ? AppColors.textPrimary : AppColors.textTertiary,
      ),
      maxLines: 1,
      textAlign: alignment == CrossAxisAlignment.start
          ? TextAlign.start
          : TextAlign.center,
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        if (size == MetricSize.hero)
          // FittedBox rather than a computed font size: the hero has to fill
          // whatever box the layout gives it, from a 4-inch phone in
          // landscape to a tablet, and measuring text to pick a size is a
          // worse answer than letting the framework scale the glyphs.
          Flexible(
            child: FittedBox(
              fit: BoxFit.contain,
              child: valueWidget,
            ),
          )
        else
          valueWidget,
        if (unit.isNotEmpty && size != MetricSize.hero) ...[
          const SizedBox(height: 2),
          Text(
            unit,
            style: AppText.unit.copyWith(fontSize: size == MetricSize.large ? 13 : 11),
            maxLines: 1,
          ),
        ],
        if (showLabel) ...[
          SizedBox(height: size == MetricSize.hero ? 6 : 4),
          Text(
            field.label,
            style: size == MetricSize.hero
                ? AppText.label.copyWith(fontSize: 14, letterSpacing: 1.2)
                : AppText.label.copyWith(fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignment == CrossAxisAlignment.start
                ? TextAlign.start
                : TextAlign.center,
          ),
        ],
      ],
    );

    if (size == MetricSize.hero) return content;

    // A supporting tile is a fixed-size stack of value, unit and label, and
    // the layout that hosts it does not always give it room: a dashboard
    // preview pane a third of the screen tall, or a landscape phone at a
    // steep angle, can leave less height than the three lines need.
    //
    // Scaling down rather than overflowing matters because the alternative is
    // not benign — a `RenderFlex` overflow is a striped bar across the screen
    // in debug and a silently clipped label in release, and the label is how
    // the rider knows which number they are looking at.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment == CrossAxisAlignment.start
          ? Alignment.centerLeft
          : Alignment.center,
      child: content,
    );
  }
}

/// The unit caption that sits beneath the hero number, e.g. `km/h`.
class HeroUnit extends StatelessWidget {
  const HeroUnit({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: AppText.unit.copyWith(fontSize: 16, letterSpacing: 2),
    );
  }
}
