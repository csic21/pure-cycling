import 'dart:async';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/elevation_chart.dart';
import '../../../shared/widgets/error_notice.dart';
import '../../../shared/widgets/route_map.dart';
import '../domain/route.dart';

/// A saved route (spec §38).
class RouteDetailScreen extends ConsumerWidget {
  const RouteDetailScreen({super.key, required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeAsync = ref.watch(routeProvider(routeId));
    final formatter = ref.watch(unitFormatterProvider);
    final tileSource = ref.watch(mapServicesProvider).tileSource;
    // Null unless the rider opted in (see `elevationProviderProvider`).
    final profile = ref.watch(routeElevationProfileProvider(routeId)).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('路线详情'),
        actions: [
          if (routeAsync.valueOrNull != null)
            IconButton(
              tooltip: '重命名',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(context, ref, routeAsync.value!),
            ),
        ],
      ),
      body: routeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, stack) => ErrorNotice(
          title: '读取路线失败',
          message: ref.read(failureReporterProvider).report(
                'route_detail.read',
                e,
                stack: stack,
                message: '本机数据库没有响应。重启应用通常可以恢复；'
                    '如果反复出现，可以在「设置 → 诊断日志」中导出日志。',
              ),
          onRetry: () => ref.invalidate(routeProvider(routeId)),
        ),
        data: (route) {
          if (route == null) {
            return const Center(child: Text('这条路线已被删除'));
          }

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Text(route.name, style: AppText.title),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          _Stat(
                            value: formatter.distanceKm(route.distanceMeters),
                            unit: formatter.system.distanceSuffix,
                            label: '距离',
                          ),
                          _Stat(
                            value: UnitFormatter.durationMinutes(
                              route.estimatedDuration,
                            ),
                            label: '预计用时',
                          ),
                          _Stat(
                            // The routing service does not know relief; the
                            // terrain service does. Prefer whichever answered.
                            value: profile != null
                                ? formatter.elevation(profile.gainMeters)
                                : route.elevationGainMeters == null
                                    ? '—'
                                    : formatter.elevation(
                                        route.elevationGainMeters!,
                                      ),
                            unit: (profile != null ||
                                    route.elevationGainMeters != null)
                                ? formatter.system.elevationSuffix
                                : null,
                            label: '爬升',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 280,
                      child: RouteMap(
                        tileSource: tileSource,
                        routePoints: route.points,
                        interactive: true,
                      ),
                    ),
                    if (profile != null) ...[
                      const SizedBox(height: 24),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Text('海拔剖面', style: AppText.sectionTitle),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: ElevationChart(
                          samples: profile.samples,
                          formatter: formatter,
                          distanceMeters: profile.distanceMeters,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Text(
                          '高程来自 ${profile.source}，'
                          '30 米分辨率：坡和垭口可信，桥、隧道口这类人工地形不可信。',
                          style: AppText.caption,
                        ),
                      ),
                    ] else if (route.elevationGainMeters == null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Text(
                          ref.watch(currentSettingsProvider).routeElevation
                              ? '高德算路不返回海拔，高程查询没有拿到结果。'
                              : '该路线由高德规划，不包含海拔数据。'
                                  '可在「设置 → 地图服务 → 路线海拔」中打开高程查询。',
                          style: AppText.caption,
                        ),
                      ),
                    if (route.instructions.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Divider(height: 1),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                        child: Text('路线指引', style: AppText.sectionTitle),
                      ),
                      for (final instruction in route.instructions)
                        _InstructionRow(instruction: instruction),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: FilledButton.icon(
                  onPressed: () => _navigate(context, ref, route),
                  icon: const Icon(Icons.navigation_outlined, size: 22),
                  label: const Text('开始导航'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _navigate(BuildContext context, WidgetRef ref, Route route) async {
    final started =
        await ref.read(rideSessionProvider.notifier).start(route: route);
    if (!context.mounted) return;

    if (!started) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法开始导航，请检查定位权限')),
      );
      return;
    }
    unawaited(context.push(AppRoutes.ride));
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Route route,
  ) async {
    final controller = TextEditingController(text: route.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名路线'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;
    await ref.read(routeRepositoryProvider).renameRoute(route.id, name);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.unit});

  final String value;
  final String? unit;
  final String label;

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

class _InstructionRow extends StatelessWidget {
  const _InstructionRow({required this.instruction});

  final RouteInstruction instruction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.hairline),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              instruction.maneuver.label,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              instruction.roadName?.isNotEmpty == true
                  ? instruction.roadName!
                  : instruction.text,
              style: AppText.body.copyWith(fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            instruction.distanceMeters < 1000
                ? '${instruction.distanceMeters.round()} m'
                : '${(instruction.distanceMeters / 1000).toStringAsFixed(1)} km',
            style: AppText.caption,
          ),
        ],
      ),
    );
  }
}
