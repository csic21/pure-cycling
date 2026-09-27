import 'dart:async';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/map/map_providers.dart';
import '../../../core/sync/functions_config.dart';
import '../../../core/utils/geo.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/route_map.dart';
import '../domain/route.dart';

/// Route planning (spec §9).
///
/// Current position to destination, with optional waypoints, and a result
/// card showing distance, time and climb. The screen is explicit about which
/// routing engine is in use: with no map key configured it says so and offers
/// a straight line, rather than silently producing a route that is not one.
class RoutePlanScreen extends ConsumerStatefulWidget {
  const RoutePlanScreen({super.key});

  @override
  ConsumerState<RoutePlanScreen> createState() => _RoutePlanScreenState();
}

class _RoutePlanScreenState extends ConsumerState<RoutePlanScreen> {
  final _destinationController = TextEditingController();
  final _waypoints = <PlaceSuggestion>[];

  GeoPoint? _origin;
  PlaceSuggestion? _destination;
  List<PlaceSuggestion> _suggestions = const [];
  Timer? _debounce;
  bool _searching = false;

  Route? _planned;
  bool _planning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveOrigin());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _destinationController.dispose();
    super.dispose();
  }

  /// Resolves the rider's current position.
  ///
  /// Falls back to the last recorded fix when the live one is unavailable, so
  /// planning still works from indoors or immediately after opening the app.
  Future<void> _resolveOrigin() async {
    final fix = await ref
        .read(locationServiceProvider)
        .currentFix(timeout: const Duration(seconds: 8));
    if (!mounted) return;

    if (fix != null && _origin == null) {
      setState(() => _origin = fix.geo);
      return;
    }
    if (_origin != null) return;

    final recent = ref.read(mostRecentRideProvider).valueOrNull;
    if (recent?.startPoint != null) {
      setState(() => _origin = recent!.startPoint);
      return;
    }

    setState(() => _error = '无法获取当前位置。请到开阔处重试，或在地图上点选起点。');
  }

  void _selectMapPoint(GeoPoint point) {
    if (_origin == null) {
      setState(() {
        _origin = point;
        _error = null;
      });
      return;
    }

    final label =
        '${point.lat.toStringAsFixed(5)}, '
        '${point.lng.toStringAsFixed(5)}';
    setState(() {
      _destination = PlaceSuggestion(name: label, point: point);
      _destinationController.text = label;
      _suggestions = const [];
      _planned = null;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    _plan();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();

    if (query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }

    // 350 ms: long enough that typing a Chinese place name does not fire a
    // request per keystroke, short enough that it feels immediate.
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final places = ref.read(mapServicesProvider).places;
      if (!places.isConfigured) return;

      setState(() => _searching = true);
      try {
        final results = await places.search(query, near: _origin, limit: 8);
        if (!mounted) return;
        setState(() {
          _suggestions = results;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searching = false);
      }
    });
  }

  Future<void> _plan() async {
    final origin = _origin;
    final destination = _destination;
    if (origin == null || destination == null) return;

    setState(() {
      _planning = true;
      _error = null;
      _planned = null;
    });

    try {
      final route = await ref
          .read(mapServicesProvider)
          .routes
          .planRoute(
            origin: origin,
            destination: destination.point,
            waypoints: _waypoints.map((w) => w.point).toList(),
          );
      if (!mounted) return;
      setState(() {
        _planned = route;
        _planning = false;
      });
    } on RoutePlanningException catch (e) {
      if (!mounted) return;
      setState(() {
        // Curated: the provider's messages are already written for the rider
        // ("高德没有返回可用的骑行路线"), so they are shown as they are.
        _error = e.message;
        _planning = false;
      });
    } catch (e, stack) {
      if (!mounted) return;
      setState(() {
        _error = ref
            .read(failureReporterProvider)
            .report(
              'route_plan.plan',
              e,
              stack: stack,
              message:
                  '规划没有完成。检查网络后重试；'
                  '如果一直失败，可以在「设置 → 诊断日志」中导出日志。',
            );
        _planning = false;
      });
    }
  }

  Future<void> _saveAndNavigate() async {
    final route = _planned;
    if (route == null) return;
    final defaultName = route.name == '骑行路线' || route.name == '直线路线';
    final named = route.copyWith(
      name: defaultName ? '前往 ${_destination?.name ?? '终点'}' : route.name,
    );
    await ref.read(routeRepositoryProvider).saveRoute(named);
    if (!mounted) return;

    final started = await ref
        .read(rideSessionProvider.notifier)
        .start(route: named);
    if (!mounted) return;

    if (!started) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法开始导航，请检查定位权限')));
      return;
    }

    // The ride screen opens on the navigation page, which the session already
    // set to the configured default presentation.
    unawaited(context.push(AppRoutes.ride));
  }

  Future<void> _saveRoute() async {
    final route = _planned;
    if (route == null) return;
    final name = await _promptName(route);
    if (name == null || !mounted) return;
    final named = route.copyWith(name: name);
    await ref.read(routeRepositoryProvider).saveRoute(named);
    if (!mounted) return;
    setState(() => _planned = named);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('路线已保存，可在「路线」中查看')));
  }

  Future<String?> _promptName(Route route) async {
    final controller = TextEditingController(text: route.name);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存路线'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '给这条路线起个名字'),
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
  }

  @override
  Widget build(BuildContext context) {
    final formatter = ref.watch(unitFormatterProvider);
    final services = ref.watch(mapServicesProvider);
    final availability = ref.watch(routingAvailabilityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('路线规划')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (!availability.available)
                  _Notice(
                    icon: Icons.info_outline,
                    text: availability.reason,
                    onTap: () => context.push(FunctionsConfig.isConfigured
                        ? AppRoutes.login
                        : AppRoutes.settingsMap),
                    actionLabel: FunctionsConfig.isConfigured ? '去登录' : '去设置',
                  ),

                _OriginRow(origin: _origin, onRefresh: _resolveOrigin),

                _DestinationField(
                  controller: _destinationController,
                  selected: _destination,
                  searching: _searching,
                  suggestions: _suggestions,
                  searchEnabled: services.canSearchPlaces,
                  onChanged: _onQueryChanged,
                  onSelected: (suggestion) {
                    setState(() {
                      _destination = suggestion;
                      _destinationController.text = suggestion.name;
                      _suggestions = const [];
                    });
                    FocusScope.of(context).unfocus();
                    _plan();
                  },
                  onClear: () => setState(() {
                    _destination = null;
                    _destinationController.clear();
                    _planned = null;
                  }),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    _origin == null ? '在地图上点选起点' : '在地图上点选终点，点击其他位置可重新选择',
                    style: AppText.caption,
                  ),
                ),
                SizedBox(
                  height: 260,
                  child: RouteMap(
                    key: ValueKey('planner-${_origin?.lat}-${_origin?.lng}'),
                    tileSource: services.tileSource,
                    center: _origin,
                    zoom: 14,
                    position: _origin,
                    destination: _destination?.point,
                    onMapTap: _selectMapPoint,
                  ),
                ),

                if (_waypoints.isNotEmpty)
                  for (var i = 0; i < _waypoints.length; i++)
                    _WaypointRow(
                      index: i + 1,
                      suggestion: _waypoints[i],
                      onRemove: () => setState(() {
                        _waypoints.removeAt(i);
                        _planned = null;
                      }),
                    ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextButton.icon(
                    onPressed: services.canSearchPlaces ? _addWaypoint : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加途经点'),
                  ),
                ),

                if (_planning)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _Notice(
                      icon: Icons.error_outline,
                      text: _error!,
                      tone: _NoticeTone.error,
                    ),
                  ),

                if (_planned != null) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  _RouteResult(
                    route: _planned!,
                    formatter: formatter,
                    services: services,
                  ),
                ],
              ],
            ),
          ),
          if (_planned != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: _saveAndNavigate,
                    icon: const Icon(Icons.navigation_outlined, size: 22),
                    label: const Text('开始导航并记录'),
                  ),
                  TextButton.icon(
                    onPressed: _saveRoute,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('只保存路线'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _addWaypoint() async {
    final places = ref.read(mapServicesProvider).places;
    final controller = TextEditingController();
    final results = ValueNotifier<List<PlaceSuggestion>>(const []);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: SizedBox(
          height: 400,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '搜索途经点'),
                  onChanged: (value) async {
                    if (value.trim().isEmpty) {
                      results.value = const [];
                      return;
                    }
                    try {
                      results.value = await places.search(
                        value.trim(),
                        near: _origin,
                        limit: 8,
                      );
                    } catch (_) {
                      results.value = const [];
                    }
                  },
                ),
              ),
              Expanded(
                child: ValueListenableBuilder<List<PlaceSuggestion>>(
                  valueListenable: results,
                  builder: (context, list, _) => ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) => ListTile(
                      title: Text(list[index].name),
                      subtitle: list[index].address == null
                          ? null
                          : Text(list[index].address!),
                      onTap: () {
                        setState(() {
                          _waypoints.add(list[index]);
                          _planned = null;
                        });
                        Navigator.pop(sheetContext);
                        _plan();
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OriginRow extends StatelessWidget {
  const _OriginRow({required this.origin, required this.onRefresh});

  final GeoPoint? origin;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: const Icon(Icons.my_location, color: AppColors.accent, size: 20),
      title: Text(
        origin == null ? '正在获取当前位置…' : '起点',
        style: AppText.body.copyWith(
          color: origin == null
              ? AppColors.textTertiary
              : AppColors.textPrimary,
        ),
      ),
      subtitle: origin == null
          ? null
          : Text(
              '${origin!.lat.toStringAsFixed(5)}, '
              '${origin!.lng.toStringAsFixed(5)}',
              style: AppText.caption,
            ),
      trailing: IconButton(
        icon: const Icon(Icons.refresh, size: 20),
        onPressed: onRefresh,
      ),
    );
  }
}

class _DestinationField extends StatelessWidget {
  const _DestinationField({
    required this.controller,
    required this.selected,
    required this.searching,
    required this.suggestions,
    required this.searchEnabled,
    required this.onChanged,
    required this.onSelected,
    required this.onClear,
  });

  final TextEditingController controller;
  final PlaceSuggestion? selected;
  final bool searching;
  final List<PlaceSuggestion> suggestions;
  final bool searchEnabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<PlaceSuggestion> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: TextField(
            controller: controller,
            enabled: searchEnabled,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: searchEnabled ? '搜索目的地' : '未配置地图服务，无法搜索',
              prefixIcon: const Icon(Icons.place_outlined, size: 20),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (selected != null
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: onClear,
                          )
                        : null),
            ),
          ),
        ),
        if (suggestions.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(suggestion.name, style: AppText.body),
                  subtitle: suggestion.address == null
                      ? null
                      : Text(
                          suggestion.address!,
                          style: AppText.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: suggestion.distanceMeters == null
                      ? null
                      : Text(
                          suggestion.distanceMeters! < 1000
                              ? '${suggestion.distanceMeters!.round()} m'
                              : '${(suggestion.distanceMeters! / 1000).toStringAsFixed(1)} km',
                          style: AppText.caption,
                        ),
                  onTap: () => onSelected(suggestion),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _WaypointRow extends StatelessWidget {
  const _WaypointRow({
    required this.index,
    required this.suggestion,
    required this.onRemove,
  });

  final int index;
  final PlaceSuggestion suggestion;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: CircleAvatar(
        radius: 12,
        backgroundColor: AppColors.surfaceRaised,
        child: Text('$index', style: AppText.caption),
      ),
      title: Text(
        suggestion.name,
        style: AppText.body,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: onRemove,
      ),
    );
  }
}

class _RouteResult extends ConsumerWidget {
  const _RouteResult({
    required this.route,
    required this.formatter,
    required this.services,
  });

  final Route route;
  final UnitFormatter formatter;
  final MapServices services;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isStraightLine = route.provider == 'offline';
    final elevationEnabled = ref.watch(currentSettingsProvider).routeElevation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isStraightLine)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _Notice(
              icon: Icons.warning_amber_outlined,
              text: '这是直线路径，不是真实骑行路线。配置高德 Key 后可获得沿道路的骑行导航。',
              tone: _NoticeTone.warning,
            ),
          ),
        SizedBox(
          height: 220,
          child: RouteMap(
            tileSource: services.tileSource,
            routePoints: route.points,
            interactive: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
              _ResultStat(
                value: formatter.distanceKm(route.distanceMeters),
                unit: formatter.system.distanceSuffix,
                label: '距离',
              ),
              _ResultStat(
                value: UnitFormatter.durationMinutes(route.estimatedDuration),
                label: '预计',
              ),
              _ResultStat(
                value: route.elevationGainMeters == null
                    ? '—'
                    : formatter.elevation(route.elevationGainMeters!),
                unit: route.elevationGainMeters == null
                    ? null
                    : formatter.system.elevationSuffix,
                label: '爬升',
              ),
            ],
          ),
        ),
        if (route.elevationGainMeters == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              // A planned route has no id yet, so the terrain lookup — which
              // is per saved route — cannot run here. Saying which step makes
              // it appear is more useful than saying it is impossible.
              elevationEnabled
                  ? '高德算路不返回海拔。保存这条路线后打开详情，即可看到高程查询给出的'
                        '爬升与剖面。'
                  : '高德算路不返回海拔。可在「设置 → 地图服务 → 路线海拔」中打开'
                        '高程查询（会把路线坐标发给第三方服务）。',
              style: AppText.caption,
            ),
          ),
        if (route.instructions.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('路线指引', style: AppText.sectionTitle),
          ),
          for (final instruction in route.instructions.take(30))
            _InstructionRow(instruction: instruction),
        ],
        const SizedBox(height: 12),
      ],
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

class _ResultStat extends StatelessWidget {
  const _ResultStat({required this.value, required this.label, this.unit});

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

enum _NoticeTone { info, warning, error }

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.tone = _NoticeTone.info,
    this.onTap,
    this.actionLabel,
  });

  final IconData icon;
  final String text;
  final _NoticeTone tone;
  final VoidCallback? onTap;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _NoticeTone.info => AppColors.textSecondary,
      _NoticeTone.warning => AppColors.warning,
      _NoticeTone.error => AppColors.danger,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: AppText.caption.copyWith(color: color)),
          ),
          if (onTap != null && actionLabel != null)
            TextButton(onPressed: onTap, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
