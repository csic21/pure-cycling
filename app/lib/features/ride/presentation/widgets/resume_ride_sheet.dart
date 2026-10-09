import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/providers.dart';
import '../../../../app/router.dart';
import '../../../../app/theme.dart';
import '../../../../core/utils/units.dart';
import '../../domain/ride_engine.dart';

/// Offers to resume a ride left behind by a crash (spec §42).
///
/// The framing matters. A rider who finds their phone has restarted does not
/// know whether their ride survived; the sheet leads with the numbers already
/// recorded, so the answer to "did I lose it?" is visible before any decision
/// is made.
///
/// Resuming is the default and the prominent action. Discarding is available
/// but secondary, and it still saves what was recorded — the only way to
/// genuinely lose a ride should be deliberately deleting it afterwards.
Future<void> showResumeRideSheet(
  BuildContext context,
  WidgetRef ref,
  RideCheckpoint checkpoint,
) {
  final formatter = ref.read(unitFormatterProvider);
  final startedAt = checkpoint.startedAt.toLocal();

  var busy = false;
  String? error;
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setState) => PopScope(
        canPop: !busy,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('发现未完成的骑行', style: AppText.title),
                const SizedBox(height: 8),
                Text(
                  '上次骑行（${UnitFormatter.shortDate(startedAt)} '
                  '${UnitFormatter.clock(startedAt)} 开始）没有正常结束，'
                  '可能是应用被系统关闭或闪退。已记录的数据都在。',
                  style: AppText.caption,
                ),
                const SizedBox(height: 20),
                _CheckpointFigures(
                  checkpoint: checkpoint,
                  formatter: formatter,
                ),
                const SizedBox(height: 24),
                if (error != null) ...[
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            final started = await ref
                                .read(rideSessionProvider.notifier)
                                .start(resumeFrom: checkpoint);
                            if (!sheetContext.mounted) return;
                            if (!started) {
                              setState(() {
                                busy = false;
                                error = '暂时无法获取定位。请检查定位权限，或选择结束并保存。';
                              });
                              return;
                            }
                            Navigator.of(sheetContext).pop();
                            if (context.mounted) {
                              unawaited(context.push(AppRoutes.ride));
                            }
                          } catch (e, stack) {
                            final message = ref
                                .read(failureReporterProvider)
                                .report(
                                  'ride.recovery.resume',
                                  e,
                                  stack: stack,
                                  message: '恢复失败，已记录的数据仍保留，请重试。',
                                );
                            if (sheetContext.mounted) {
                              setState(() {
                                busy = false;
                                error = message;
                              });
                            }
                          }
                        },
                  child: const Text('继续这次骑行'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            final ride = await ref
                                .read(rideRecorderProvider)
                                .finishRecoveredRide(checkpoint);
                            if (!sheetContext.mounted) return;
                            Navigator.of(sheetContext).pop();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '已保存 ${ride.distanceMeters ~/ 1000} 公里的记录',
                                  ),
                                ),
                              );
                              context.go(AppRoutes.history);
                            }
                          } catch (e, stack) {
                            final message = ref
                                .read(failureReporterProvider)
                                .report(
                                  'ride.recovery.save',
                                  e,
                                  stack: stack,
                                  message: '保存失败，已记录的数据仍保留，请重试。',
                                );
                            if (sheetContext.mounted) {
                              setState(() {
                                busy = false;
                                error = message;
                              });
                            }
                          }
                        },
                  child: const Text('结束并保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _CheckpointFigures extends StatelessWidget {
  const _CheckpointFigures({required this.checkpoint, required this.formatter});

  final RideCheckpoint checkpoint;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.hairline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _Cell(
            value: formatter.distanceKm(checkpoint.distanceMeters),
            unit: formatter.system.distanceSuffix,
            label: '已骑',
          ),
          _Cell(value: UnitFormatter.duration(checkpoint.elapsed), label: '用时'),
          _Cell(
            value: formatter.elevation(checkpoint.elevationGainMeters),
            unit: formatter.system.elevationSuffix,
            label: '爬升',
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.value, required this.label, this.unit});

  final String value;
  final String label;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          // Scaled down rather than allowed to overflow. Three of these sit
          // side by side in a sheet the width of the phone, and "1:02:36 h"
          // with a unit is wider than a third of it — a `RenderFlex` overflow
          // is a striped bar in debug and a clipped digit in release, and a
          // clipped duration reads as a shorter ride than the rider had.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: AppText.value),
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
