import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/location/elevation_tuning.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/elevation_chart.dart';
import '../../../shared/widgets/route_map.dart';
import '../../ride/domain/ride.dart';

/// A single ride (spec §36).
///
/// The order is the order a rider reads their own ride in: the headline
/// distance, then how long and how fast, then the shape of it. The map and the
/// elevation profile come last because they answer "where" and "what was it
/// like" — questions that only come up after "how did I do".
class RideDetailScreen extends ConsumerStatefulWidget {
  const RideDetailScreen({super.key, required this.rideId});

  final String rideId;

  @override
  ConsumerState<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends ConsumerState<RideDetailScreen> {
  @override
  void initState() {
    super.initState();
    // A ride restored onto a new phone arrives as a summary plus a GPX object
    // in Storage. Its trace is fetched lazily, the first time somebody
    // actually opens it — there is no point downloading four thousand points
    // for a ride nobody looks at.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncServiceProvider).hydrateTrace(widget.rideId).catchError((_) => 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rideAsync = ref.watch(rideProvider(widget.rideId));
    final formatter = ref.watch(unitFormatterProvider);
    final tileSource = ref.watch(mapServicesProvider).tileSource;

    return Scaffold(
      appBar: AppBar(
        title: const Text('骑行详情'),
        actions: [
          if (rideAsync.valueOrNull != null)
            IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz),
              onPressed: () => _showActions(rideAsync.valueOrNull!),
            ),
        ],
      ),
      body: rideAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (ride) {
          if (ride == null) {
            return const Center(child: Text('这条记录已被删除'));
          }

          final track = ref.watch(trackGeometryProvider(widget.rideId));
          final elevation = ref.watch(elevationSamplesProvider(widget.rideId));

          final elevationQuality =
              ref.watch(elevationQualityProvider(widget.rideId));

          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              _Header(ride: ride, formatter: formatter),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _StatsGrid(
                  ride: ride,
                  formatter: formatter,
                  elevationQuality: elevationQuality,
                ),
              ),
              if (elevationQuality.isApproximate)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    '这台设备没有提供可靠的高度数据（例如没有气压计）。'
                    '爬升和坡度是估算值，可能偏离实际。',
                    style: AppText.caption,
                  ),
                ),
              const SizedBox(height: 24),
              if (track.isNotEmpty) ...[
                const Divider(height: 1),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('轨迹', style: AppText.sectionTitle),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 240,
                  child: RouteMap(
                    tileSource: tileSource,
                    trackPoints: track,
                    interactive: true,
                  ),
                ),
                const SizedBox(height: 24),
              ],
              if (elevation.length > 1) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('海拔', style: AppText.sectionTitle),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ElevationChart(
                    samples: elevation,
                    formatter: formatter,
                    distanceMeters: ride.stats.distanceMeters,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OutlinedButton.icon(
                  onPressed: () => _exportGpx(ride),
                  icon: const Icon(Icons.ios_share, size: 20),
                  label: const Text('导出 GPX'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showActions(Ride ride) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(sheetContext);
                _rename(ride);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出 GPX'),
              onTap: () {
                Navigator.pop(sheetContext);
                _exportGpx(ride);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: const Text(
                '删除这条记录',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(ride);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Ride ride) async {
    final controller = TextEditingController(text: ride.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：周末环湖'),
        ),
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

    if (name == null || !mounted) return;
    await ref
        .read(rideRepositoryProvider)
        .updateMetadata(ride.id, name: name.isEmpty ? null : name);
  }

  Future<void> _exportGpx(Ride ride) async {
    try {
      final file = await ref.read(rideRepositoryProvider).exportGpx(ride);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/gpx+xml')],
          subject: ride.displayName('骑行'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _confirmDelete(Ride ride) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: const Text('删除后无法恢复。如果已经同步到云端，其他设备上也会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(rideRepositoryProvider).deleteRide(ride.id);
    if (mounted) Navigator.of(context).pop();
  }

}

class _Header extends StatelessWidget {
  const _Header({required this.ride, required this.formatter});

  final Ride ride;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final local = ride.startedAt.toLocal();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${UnitFormatter.dateHeading(local)} ${UnitFormatter.clock(local)}',
            style: AppText.sectionTitle,
          ),
          const SizedBox(height: 4),
          Text(
            ride.displayName('骑行'),
            style: AppText.title,
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                formatter.distanceKm(ride.stats.distanceMeters),
                style: AppText.hero(64),
              ),
              const SizedBox(width: 8),
              Text(
                formatter.system.distanceSuffix,
                style: AppText.unit.copyWith(fontSize: 16),
              ),
            ],
          ),
          if (ride.syncStatus.isPending) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.cloud_off_outlined,
                  size: 14,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: 5),
                Text(ride.syncStatus.label, style: AppText.caption),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({
    required this.ride,
    required this.formatter,
    this.elevationQuality = ElevationQuality.fair,
  });

  final Ride ride;
  final UnitFormatter formatter;

  /// How much the climb and grade figures can be trusted.
  final ElevationQuality elevationQuality;

  @override
  Widget build(BuildContext context) {
    final stats = ride.stats;

    return Column(
      children: [
        const Divider(height: 1),
        Row(
          children: [
            _Stat(
              value: UnitFormatter.duration(stats.moving),
              label: '移动时间',
            ),
            _Stat(
              value: formatter.speed(stats.avgSpeedMps),
              unit: formatter.system.speedSuffix,
              label: '平均速度',
            ),
          ],
        ),
        const Divider(height: 1),
        Row(
          children: [
            _Stat(
              value: UnitFormatter.duration(stats.elapsed),
              label: '总用时',
            ),
            _Stat(
              value: formatter.speed(stats.maxSpeedMps),
              unit: formatter.system.speedSuffix,
              label: '最大速度',
            ),
          ],
        ),
        const Divider(height: 1),
        Row(
          children: [
            _Stat(
              value: formatter.elevationWithUnit(stats.elevationGainMeters),
              // Labelled as an estimate rather than presented as a
              // measurement. On a phone without a barometer the drift in GPS
              // altitude is the same order of magnitude as a real short climb,
              // and no filter can separate them — so the honest thing is to
              // say so rather than to show a confident number.
              label: elevationQuality.isApproximate ? '爬升（估算）' : '爬升',
            ),
            _Stat(
              value: formatter.elevationWithUnit(stats.elevationLossMeters),
              label: elevationQuality.isApproximate ? '下降（估算）' : '下降',
            ),
          ],
        ),
        const Divider(height: 1),
        if (stats.avgHeartRate != null ||
            stats.avgCadence != null ||
            stats.avgPower != null) ...[
          Row(
            children: [
              _Stat(
                value: stats.avgHeartRate?.toString() ?? '--',
                unit: 'bpm',
                label: '平均心率',
              ),
              _Stat(
                value: stats.avgCadence?.toString() ?? '--',
                unit: 'rpm',
                label: '平均踏频',
              ),
              _Stat(
                value: stats.avgPower?.toString() ?? '--',
                unit: 'W',
                label: '平均功率',
              ),
            ],
          ),
          const Divider(height: 1),
        ],
      ],
    );
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
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
      ),
    );
  }
}

