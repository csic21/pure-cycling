import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../ride/domain/ride.dart';
import 'widgets/ride_summary_row.dart';

/// The history list (spec §37).
///
/// A tool list, not a feed. Month totals at the top, then a reverse-
/// chronological list of rides grouped by nothing — dates are already in every
/// row, and invented groupings make a short list look busy.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rides = ref.watch(ridesProvider);
    final summary = ref.watch(monthSummaryProvider);
    final month = ref.watch(selectedMonthProvider);
    final formatter = ref.watch(unitFormatterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('记录'),
        actions: [
          IconButton(
            tooltip: '上个月',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftMonth(ref, month, -1),
          ),
          IconButton(
            tooltip: '下个月',
            icon: const Icon(Icons.chevron_right),
            onPressed: month.year == DateTime.now().year &&
                    month.month == DateTime.now().month
                ? null
                : () => _shiftMonth(ref, month, 1),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surfaceRaised,
        onRefresh: () => ref.read(syncServiceProvider).syncNow(force: true),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _MonthHeader(
                month: month,
                summary: summary.valueOrNull,
                formatter: formatter,
              ),
            ),
            rides.when(
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: _Message(text: '读取记录失败：$error'),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(month: month),
                  );
                }
                return SliverList.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final ride = list[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: RideSummaryRow(
                        ride: ride,
                        formatter: formatter,
                        onTap: () =>
                            context.push(AppRoutes.rideDetailFor(ride.id)),
                      ),
                    );
                  },
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  static void _shiftMonth(WidgetRef ref, DateTime month, int delta) {
    final next = DateTime(month.year, month.month + delta);
    final now = DateTime.now();
    // Do not allow browsing into the future: an empty future month is a dead
    // end that looks like a bug.
    if (next.isAfter(DateTime(now.year, now.month))) return;
    ref.read(selectedMonthProvider.notifier).state = next;
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.summary,
    required this.formatter,
  });

  final DateTime month;
  final RideSummary? summary;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final isCurrent =
        month.year == DateTime.now().year && month.month == DateTime.now().month;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                UnitFormatter.monthHeading(month),
                style: AppText.sectionTitle,
              ),
              if (isCurrent) ...[
                const SizedBox(width: 8),
                Text(
                  '本月',
                  style: AppText.caption.copyWith(color: AppColors.accent),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          if (summary == null || summary!.rideCount == 0)
            const Text('本月还没有骑行', style: AppText.caption)
          else
            Row(
              children: [
                _Total(
                  value: formatter.distanceKm(summary!.distanceMeters),
                  unit: formatter.system.distanceSuffix,
                  label: '里程',
                  emphasized: true,
                ),
                _Total(
                  value: '${summary!.rideCount}',
                  unit: '次',
                  label: '骑行次数',
                ),
                _Total(
                  value: UnitFormatter.durationCompact(summary!.moving),
                  label: '移动时间',
                ),
                _Total(
                  value: formatter.elevation(summary!.elevationGainMeters),
                  unit: formatter.system.elevationSuffix,
                  label: '爬升',
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({
    required this.value,
    required this.label,
    this.unit,
    this.emphasized = false,
  });

  final String value;
  final String? unit;
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: emphasized
                      ? AppText.value.copyWith(fontSize: 26)
                      : AppText.value,
                ),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(unit!, style: AppText.caption.copyWith(fontSize: 10)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: AppText.caption),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final isCurrent =
        month.year == DateTime.now().year && month.month == DateTime.now().month;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.directions_bike_outlined,
              size: 48,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              isCurrent ? '本月还没有骑行记录' : '这个月没有骑行记录',
              style: AppText.body,
            ),
            const SizedBox(height: 6),
            const Text(
              '回到「骑行」开始记录吧',
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(text, style: AppText.caption, textAlign: TextAlign.center),
      ),
    );
  }
}
