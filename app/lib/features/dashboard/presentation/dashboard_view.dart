import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../../shared/layout/handlebar.dart';
import '../../../shared/widgets/maneuver_icon.dart';
import '../../../shared/widgets/metric_tile.dart';
import '../../navigation/domain/navigation_state.dart';
import '../domain/dashboard_config.dart';
import '../domain/dashboard_field.dart';

/// Renders one dashboard page.
///
/// The three layouts from spec §6 are all the same idea — a hero number with
/// supporting values beneath it, or an even grid — so they share one widget
/// tree and differ only in how the space is divided. Adding a fourth layout is
/// a case in [DashboardLayout] plus a branch here.
class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.page,
    required this.data,
    required this.formatter,
    this.dimmed = false,
    this.minimal = false,
  });

  final DashboardPage page;
  final DashboardData data;
  final UnitFormatter formatter;

  /// Hides the supporting values, keeping only the hero number. Used by the
  /// standstill dimmer and by the minimal OLED mode.
  final bool dimmed;

  /// The stripped-down readout of spec §7.4.
  final bool minimal;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side once the phone is mounted sideways. A hero stacked
        // over its grid has about a third of the height it needs in that
        // frame. The cut itself lives in [isHandlebarLandscape].
        final landscape = isHandlebarLandscape(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        if (minimal) {
          return _MinimalDashboard(
            data: data,
            formatter: formatter,
            landscape: landscape,
          );
        }

        return switch (page.layout) {
          DashboardLayout.grid6 => _buildGrid(landscape),
          DashboardLayout.hero2 ||
          DashboardLayout.hero4 => _buildHero(landscape),
        };
      },
    );
  }

  Widget _buildHero(bool landscape) {
    final hero = page.heroField ?? DashboardField.speed;
    final supporting = page.supportingFields();
    final showSupporting = !dimmed && supporting.isNotEmpty;

    final heroBlock = Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MetricTile(
              field: hero,
              data: data,
              formatter: formatter,
              size: MetricSize.hero,
              showLabel: false,
            ),
          ),
          const SizedBox(height: 8),
          HeroUnit(text: hero.unitLabel(data, formatter)),
        ],
      ),
    );

    if (landscape) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Expanded(flex: showSupporting ? 5 : 1, child: heroBlock),
            if (showSupporting) ...[
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                flex: 4,
                child: _SupportingGrid(
                  fields: supporting,
                  data: data,
                  formatter: formatter,
                  columns: 2,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          // 5 : 4 gives the hero number roughly 45% of the page, comfortably
          // above the "at least 20% of screen height" floor in spec §5.1 once
          // the app bar and page dots are accounted for.
          Expanded(flex: 5, child: heroBlock),
          if (!dimmed) ...[
            const Divider(height: 1),
            Expanded(
              flex: 4,
              child: _SupportingGrid(
                fields: supporting,
                data: data,
                formatter: formatter,
                columns: 2,
              ),
            ),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildGrid(bool landscape) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: _SupportingGrid(
        fields: page.supportingFields(),
        data: data,
        formatter: formatter,
        // Six fields read better as three columns of two in a short, wide
        // frame; two columns of three would leave each row cramped.
        columns: landscape ? 3 : 2,
        size: MetricSize.large,
        rules: dimmed,
      ),
    );
  }
}

class _SupportingGrid extends StatelessWidget {
  const _SupportingGrid({
    required this.fields,
    required this.data,
    required this.formatter,
    required this.columns,
    this.size = MetricSize.medium,
    this.rules = false,
  });

  final List<DashboardField> fields;
  final DashboardData data;
  final UnitFormatter formatter;
  final int columns;
  final MetricSize size;

  /// Draws hairline separators. The spec's mock-ups use them, and on a
  /// pure-black background a faint rule is the only structure available that
  /// does not cost power.
  final bool rules;

  @override
  Widget build(BuildContext context) {
    if (fields.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += columns) {
      final rowFields = fields.skip(i).take(columns).toList();
      rows.add(
        Expanded(
          child: Row(
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (rules && c > 0)
                  const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: c < rowFields.length
                      ? Center(
                          child: MetricTile(
                            field: rowFields[c],
                            data: data,
                            formatter: formatter,
                            size: size,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );

      if (rules && i + columns < fields.length) {
        rows.add(const Divider(height: 1, thickness: 1));
      }
    }

    return Column(children: rows);
  }
}

/// The minimal OLED readout (spec §7.4).
///
/// Speed, climb and the next turn — nothing else. The point is that this is
/// readable at a glance in bright sun and costs almost nothing to keep on a
/// screen for four hours.
class _MinimalDashboard extends StatelessWidget {
  const _MinimalDashboard({
    required this.data,
    required this.formatter,
    required this.landscape,
  });

  final DashboardData data;
  final UnitFormatter formatter;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final navigation = data.navigation;
    final stats = data.stats;

    final speed = MetricTile(
      field: DashboardField.speed,
      data: data,
      formatter: formatter,
      size: MetricSize.hero,
      showLabel: false,
    );

    final supporting = <Widget>[
      _CompactStat(
        value:
            '${formatter.distanceKm(stats.distanceMeters, decimals: 1)}'
            ' ${formatter.system.distanceSuffix}',
      ),
      _CompactStat(
        value: formatter.elevationWithUnit(
          stats.elevationGainMeters,
          withSign: true,
        ),
      ),
      _CompactStat(value: UnitFormatter.duration(stats.moving)),
    ];

    if (landscape) {
      // Same information, rotated with the phone: speed beside the numbers
      // instead of above them, because a short frame has no room for a stack.
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Expanded(flex: 3, child: Center(child: speed)),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              flex: 2,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (navigation?.distanceToNextTurnMeters != null)
                    _TurnHint(navigation: navigation!, formatter: formatter),
                  ...supporting,
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          Expanded(flex: 6, child: Center(child: speed)),
          if (navigation?.distanceToNextTurnMeters != null)
            _TurnHint(navigation: navigation!, formatter: formatter),
          Expanded(
            flex: 4,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: supporting,
            ),
          ),
        ],
      ),
    );
  }
}

class _TurnHint extends StatelessWidget {
  const _TurnHint({required this.navigation, required this.formatter});

  final NavigationSnapshot navigation;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final instruction = navigation.currentInstruction;
    final distance = navigation.distanceToNextTurnMeters;
    if (instruction == null || distance == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ManeuverIcon(maneuver: instruction.maneuver, size: 22),
          const SizedBox(width: 8),
          Text(
            distance < 1000
                ? '${distance.round()} m'
                : '${(distance / 1000).toStringAsFixed(1)} km',
            style: AppText.value,
          ),
        ],
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  const _CompactStat({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(value, style: AppText.value);
  }
}
