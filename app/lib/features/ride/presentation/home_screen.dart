import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/location/location_service.dart';
import '../../../core/utils/units.dart';
import '../../history/presentation/widgets/ride_summary_row.dart';
import '../domain/ride.dart';
import 'widgets/location_notice.dart';
import 'widgets/resume_ride_sheet.dart';

/// The home screen (spec §4).
///
/// Deliberately not a feed. The whole screen exists to make 开始骑行 findable
/// within a second of the app opening, and to answer one question — how much
/// have I ridden this month — without a tap.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(monthSummaryProvider);
    final recent = ref.watch(mostRecentRideProvider);
    final formatter = ref.watch(unitFormatterProvider);

    // Selected, not watched wholesale: this provider emits about once a second
    // while riding, and the home screen has no number that needs to tick.
    final recording = ref.watch(
      rideSessionProvider.select((s) => s.ride.isRecording),
    );

    // Offered once, on first build of this screen. The dialog does not
    // re-open when the row changes, which is why this is a one-shot provider
    // rather than a stream.
    ref.listen(unfinishedRideProvider, (previous, next) {
      final checkpoint = next.valueOrNull;
      if (checkpoint == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        showResumeRideSheet(context, ref, checkpoint);
      });
    });

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const Text(
                '今天骑车？',
                style: AppText.sectionTitle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              _MonthDistance(
                summary: summary.valueOrNull,
                formatter: formatter,
                loading: summary.isLoading,
              ),
              const Spacer(flex: 3),
              if (recording) ...[
                _RecordingBanner(
                  onTap: () => context.push(AppRoutes.ride),
                ),
                const SizedBox(height: 14),
              ],
              _StartRideButton(
                recording: recording,
                onStart: () => recording
                    ? context.push(AppRoutes.ride)
                    : _startRide(context, ref),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push(AppRoutes.routePlan),
                      icon: const Icon(Icons.route, size: 20),
                      label: const Text('路线规划'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push(AppRoutes.routeImport),
                      icon: const Icon(Icons.file_download_outlined, size: 20),
                      label: const Text('导入 GPX'),
                    ),
                  ),
                ],
              ),
              const Spacer(flex: 2),
              if (recent.valueOrNull != null) ...[
                const Divider(height: 1),
                const SizedBox(height: 16),
                const Text('最近一次', style: AppText.sectionTitle),
                const SizedBox(height: 10),
                RideSummaryRow(
                  ride: recent.valueOrNull!,
                  formatter: formatter,
                  onTap: () => context.push(
                    AppRoutes.rideDetailFor(recent.valueOrNull!.id),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Starts a ride, checking location before leaving the screen.
  ///
  /// The permission check happens here rather than on the ride screen so a
  /// refusal is explained *before* the rider has mounted their phone and is
  /// waiting for something to happen.
  ///
  /// It also runs the disclosure that has to come before the system dialog —
  /// see [showLocationDisclosure] — and, once, the warning that a
  /// foreground-only grant will not survive the screen going off.
  Future<void> _startRide(BuildContext context, WidgetRef ref) async {
    final store = ref.read(settingsRepositoryProvider);

    if (await store.getString(LocationNoticeKeys.disclosureSeen) !=
        LocationNoticeKeys.seen) {
      if (!context.mounted) return;
      final agreed = await showLocationDisclosure(context);
      if (!agreed || !context.mounted) return;
      await store.setString(
        LocationNoticeKeys.disclosureSeen,
        LocationNoticeKeys.seen,
      );
    }

    final permission = await ref.read(locationServiceProvider).checkPermission();

    if (permission == LocationPermissionStatus.serviceDisabled) {
      if (!context.mounted) return;
      await _showLocationProblem(
        context,
        title: '系统定位服务未开启',
        message: '骑行记录需要定位权限。请打开系统设置中的「定位服务」后重试。',
        actionLabel: '打开设置',
        onAction: () => ref.read(locationServiceProvider).openLocationSettings(),
      );
      return;
    }

    if (permission == LocationPermissionStatus.deniedForever) {
      if (!context.mounted) return;
      await _showLocationProblem(
        context,
        title: '定位权限已被拒绝',
        message: '请在系统设置中允许「纯粹骑行」使用定位，然后回到这里重新开始。',
        actionLabel: '打开设置',
        onAction: () => ref.read(locationServiceProvider).openAppSettings(),
      );
      return;
    }

    if (await ref.read(locationServiceProvider).hasBackgroundAccess() == false &&
        await store.getString(LocationNoticeKeys.backgroundHintSeen) !=
            LocationNoticeKeys.seen) {
      if (!context.mounted) return;
      await showBackgroundLocationHint(context);
      await store.setString(
        LocationNoticeKeys.backgroundHintSeen,
        LocationNoticeKeys.seen,
      );
      if (!context.mounted) return;
    }

    if (!context.mounted) return;
    // Not awaited: the router owns the navigation, and there is nothing to do
    // with its result here. Saying so explicitly beats a lint suppression.
    unawaited(context.push(AppRoutes.ride));
  }

  static Future<void> _showLocationProblem(
    BuildContext context, {
    required String title,
    required String message,
    required String actionLabel,
    required Future<bool> Function() onAction,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              onAction();
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _MonthDistance extends StatelessWidget {
  const _MonthDistance({
    required this.summary,
    required this.formatter,
    required this.loading,
  });

  final RideSummary? summary;
  final UnitFormatter formatter;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final value = summary?.distanceMeters ?? 0;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text('本月 ', style: AppText.label),
            Text(
              loading ? '—' : formatter.distanceKm(value),
              style: AppText.hero(46),
            ),
            const SizedBox(width: 6),
            Text(
              formatter.system.distanceSuffix,
              style: AppText.unit.copyWith(fontSize: 15),
            ),
          ],
        ),
        if (summary != null && summary!.rideCount > 0) ...[
          const SizedBox(height: 6),
          Text(
            '${summary!.rideCount} 次 · '
            '${UnitFormatter.durationCompact(summary!.moving)}',
            style: AppText.caption,
          ),
        ],
      ],
    );
  }
}

/// Says a ride is still being recorded.
///
/// The ride screen guards its own exits, so this should be rare — but "rare"
/// is not "impossible", and the alternative is a home screen offering 开始骑行
/// while a ride is live. That is not just misleading: starting a second ride
/// tears down the running engine, and the ride in progress becomes a partial
/// record nobody asked for.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.accent),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.fiber_manual_record, size: 14, color: AppColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text('正在记录', style: AppText.body),
              ),
              Text('回到码表', style: AppText.caption),
            ],
          ),
        ),
      ),
    );
  }
}

/// The primary action.
///
/// Sized and coloured so it is unmissable on a black screen — the one place
/// the accent colour is used at full strength on this page.
class _StartRideButton extends StatelessWidget {
  const _StartRideButton({required this.onStart, required this.recording});

  final VoidCallback onStart;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: FilledButton(
        onPressed: onStart,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              recording ? Icons.arrow_forward_rounded : Icons.play_arrow_rounded,
              size: 30,
              color: Colors.black,
            ),
            const SizedBox(width: 8),
            // No colour here: the label inherits the button's foreground, so
            // it follows the theme instead of repeating it.
            Text(recording ? '返回骑行' : '开始骑行', style: AppText.cta),
          ],
        ),
      ),
    );
  }
}
