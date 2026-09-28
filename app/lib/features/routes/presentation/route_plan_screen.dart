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
  String? _searchError;
  int _searchEpoch = 0;
  int _originEpoch = 0;
  int _planEpoch = 0;
  bool _resolvingOrigin = false;
  bool _pickingOrigin = false;

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
  Future<void> _resolveOrigin({bool force = false}) async {
    final epoch = ++_originEpoch;
    setState(() => _resolvingOrigin = true);
    final fix = await ref
        .read(locationServiceProvider)
        .currentFix(timeout: const Duration(seconds: 8));
    if (!mounted || epoch != _originEpoch) return;

    if (fix != null) {
      final shouldReplan = force || _origin == null;
      setState(() {
        _resolvingOrigin = false;
        if (shouldReplan) {
          _origin = fix.geo;
          _pickingOrigin = false;
          _invalidatePlan();
          _error = null;
        }
      });
      if (shouldReplan && _destination != null) unawaited(_plan());
      return;
    }
    if (_origin != null) {
      setState(() {
        _resolvingOrigin = false;
        if (force) _error = '暂时无法更新当前位置，仍使用原来的起点。也可以在地图上重选。';
      });
      return;
    }

    final recent = ref.read(mostRecentRideProvider).valueOrNull;
    if (recent?.startPoint != null) {
      setState(() {
        _origin = recent!.startPoint;
        _resolvingOrigin = false;
      });
      return;
    }

    setState(() {
      _resolvingOrigin = false;
      _error = '无法获取当前位置。请到开阔处重试，或在地图上点选起点。';
    });
  }

  void _invalidatePlan() {
    _planEpoch++;
    _planned = null;
    _planning = false;
  }

  void _selectMapPoint(GeoPoint point) {
    _searchEpoch++;
    _debounce?.cancel();
    if (_origin == null || _pickingOrigin) {
      setState(() {
        _origin = point;
        _pickingOrigin = false;
        _suggestions = const [];
        _searching = false;
        _searchError = null;
        _invalidatePlan();
        _error = null;
      });
      if (_destination != null) _plan();
      return;
    }

    final label =
        '${point.lat.toStringAsFixed(5)}, '
        '${point.lng.toStringAsFixed(5)}';
    setState(() {
      _destination = PlaceSuggestion(name: label, point: point);
      _destinationController.text = label;
      _suggestions = const [];
      _searching = false;
      _searchError = null;
      _invalidatePlan();
      _error = null;
    });
    FocusScope.of(context).unfocus();
    _plan();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final epoch = ++_searchEpoch;
    final query = value.trim();

    setState(() {
      _destination = null;
      _suggestions = const [];
      _searching = false;
      _searchError = null;
      _invalidatePlan();
    });

    if (query.isEmpty) {
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
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _suggestions = results;
          _searching = false;
        });
      } on RoutePlanningException catch (error) {
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _searching = false;
          _searchError = error.message;
        });
      } catch (_) {
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _searching = false;
          _searchError = '地点搜索暂时不可用，请稍后重试';
        });
      }
    });
  }

  Future<void> _plan() async {
    final origin = _origin;
    final destination = _destination;
    if (origin == null || destination == null) return;
    final epoch = ++_planEpoch;

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
      if (!mounted || epoch != _planEpoch) return;
      setState(() {
        _planned = route;
        _planning = false;
      });
    } on RoutePlanningException catch (e) {
      if (!mounted || epoch != _planEpoch) return;
      setState(() {
        // Curated: the provider's messages are already written for the rider
        // ("高德没有返回可用的骑行路线"), so they are shown as they are.
        _error = e.message;
        _planning = false;
      });
    } catch (e, stack) {
      if (!mounted || epoch != _planEpoch) return;
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
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                if (!availability.available)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: _Notice(
                      icon: Icons.info_outline,
                      text: availability.reason,
                      onTap: () => context.push(
                        FunctionsConfig.isConfigured
                            ? AppRoutes.login
                            : AppRoutes.settingsMap,
                      ),
                      actionLabel: FunctionsConfig.isConfigured ? '去登录' : '去设置',
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.hairlineStrong),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Column(
                        children: [
                          _OriginRow(
                            origin: _origin,
                            resolving: _resolvingOrigin,
                            picking: _pickingOrigin,
                            onRefresh: () =>
                                unawaited(_resolveOrigin(force: true)),
                            onPick: () => setState(() => _pickingOrigin = true),
                          ),
                          for (var i = 0; i < _waypoints.length; i++)
                            _WaypointRow(
                              index: i + 1,
                              suggestion: _waypoints[i],
                              onRemove: () {
                                setState(() {
                                  _waypoints.removeAt(i);
                                  _invalidatePlan();
                                });
                                _plan();
                              },
                            ),
                          const Divider(height: 16),
                          _DestinationField(
                            controller: _destinationController,
                            searching: _searching,
                            suggestions: _suggestions,
                            searchError: _searchError,
                            searchEnabled: services.canSearchPlaces,
                            unavailableHint: FunctionsConfig.isConfigured
                                ? '登录后可搜索目的地'
                                : '未配置地图服务，无法搜索',
                            onChanged: _onQueryChanged,
                            onSelected: (suggestion) {
                              _searchEpoch++;
                              _debounce?.cancel();
                              setState(() {
                                _destination = suggestion;
                                _destinationController.text = suggestion.name;
                                _suggestions = const [];
                                _searching = false;
                                _searchError = null;
                                _invalidatePlan();
                              });
                              FocusScope.of(context).unfocus();
                              _plan();
                            },
                            onClear: () {
                              _searchEpoch++;
                              _debounce?.cancel();
                              setState(() {
                                _destination = null;
                                _destinationController.clear();
                                _suggestions = const [];
                                _searching = false;
                                _invalidatePlan();
                              });
                            },
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: services.canSearchPlaces
                                  ? _addWaypoint
                                  : null,
                              icon: const Icon(
                                Icons.add_circle_outline,
                                size: 18,
                              ),
                              label: const Text('添加途经点'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('地图选点', style: AppText.sectionTitle),
                      ),
                      if (_origin != null)
                        TextButton(
                          onPressed: () =>
                              setState(() => _pickingOrigin = !_pickingOrigin),
                          child: Text(_pickingOrigin ? '取消重选' : '重选起点'),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 300,
                      child: RouteMap(
                        key: ValueKey((
                          _planned,
                          _destination,
                          _origin,
                          _waypoints.length,
                        )),
                        tileSource: services.tileSource,
                        center: _origin,
                        zoom: 14,
                        fitPoints: [
                          ?_origin,
                          ..._waypoints.map((point) => point.point),
                          ?_destination?.point,
                        ],
                        routePoints: _planned?.points ?? const [],
                        position: _origin,
                        waypoints: _waypoints
                            .map((point) => point.point)
                            .toList(),
                        destination: _destination?.point,
                        onMapTap: _selectMapPoint,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Text(
                    _origin == null
                        ? '在地图上点选起点'
                        : _pickingOrigin
                        ? '在地图上点选新的起点'
                        : '在地图上点选终点，点击其他位置可重新选择',
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),

                if (_planning)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
                    child: LinearProgressIndicator(minHeight: 3),
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
                  const SizedBox(height: 20),
                  _RouteResult(route: _planned!, formatter: formatter),
                ],
              ],
            ),
          ),
          if (_planned != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
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
            ),
        ],
      ),
    );
  }

  Future<void> _addWaypoint() async {
    final places = ref.read(mapServicesProvider).places;
    final controller = TextEditingController();
    final searchState =
        ValueNotifier<
          ({List<PlaceSuggestion> items, bool loading, String message})
        >((items: const [], loading: false, message: '输入地点名称搜索途经点'));
    Timer? debounce;
    var searchEpoch = 0;
    var sheetOpen = true;

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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('添加途经点', style: AppText.title),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '搜索途经点'),
                  onChanged: (value) {
                    debounce?.cancel();
                    final epoch = ++searchEpoch;
                    final query = value.trim();
                    if (query.isEmpty) {
                      searchState.value = (
                        items: const [],
                        loading: false,
                        message: '输入地点名称搜索途经点',
                      );
                      return;
                    }
                    searchState.value = (
                      items: const [],
                      loading: true,
                      message: '',
                    );
                    debounce = Timer(
                      const Duration(milliseconds: 350),
                      () async {
                        try {
                          final found = await places.search(
                            query,
                            near: _origin,
                            limit: 8,
                          );
                          if (sheetOpen && epoch == searchEpoch) {
                            searchState.value = (
                              items: found,
                              loading: false,
                              message: found.isEmpty ? '没有找到相关地点，请换个关键词' : '',
                            );
                          }
                        } on RoutePlanningException catch (error) {
                          if (sheetOpen && epoch == searchEpoch) {
                            searchState.value = (
                              items: const [],
                              loading: false,
                              message: error.message,
                            );
                          }
                        } catch (_) {
                          if (sheetOpen && epoch == searchEpoch) {
                            searchState.value = (
                              items: const [],
                              loading: false,
                              message: '地点搜索暂时不可用，请稍后重试',
                            );
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              Expanded(
                child:
                    ValueListenableBuilder<
                      ({
                        List<PlaceSuggestion> items,
                        bool loading,
                        String message,
                      })
                    >(
                      valueListenable: searchState,
                      builder: (context, state, _) {
                        if (state.loading) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (state.items.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                state.message,
                                style: AppText.body.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: state.items.length,
                          itemBuilder: (context, index) => ListTile(
                            title: Text(state.items[index].name),
                            subtitle: state.items[index].address == null
                                ? null
                                : Text(state.items[index].address!),
                            onTap: () {
                              setState(() {
                                _waypoints.add(state.items[index]);
                                _invalidatePlan();
                              });
                              Navigator.pop(sheetContext);
                              _plan();
                            },
                          ),
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    );
    sheetOpen = false;
    debounce?.cancel();
    controller.dispose();
    searchState.dispose();
  }
}

class _OriginRow extends StatelessWidget {
  const _OriginRow({
    required this.origin,
    required this.resolving,
    required this.picking,
    required this.onRefresh,
    required this.onPick,
  });

  final GeoPoint? origin;
  final bool resolving;
  final bool picking;
  final VoidCallback onRefresh;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 40,
          child: Icon(
            Icons.radio_button_checked,
            color: AppColors.accent,
            size: 20,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '起点',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  picking
                      ? '点选新的起点'
                      : origin == null
                      ? resolving
                            ? '正在获取当前位置…'
                            : '等待选择起点'
                      : '${origin!.lat.toStringAsFixed(5)}, ${origin!.lng.toStringAsFixed(5)}',
                  style: AppText.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '在地图上重选起点',
          icon: const Icon(Icons.edit_location_alt_outlined, size: 21),
          onPressed: onPick,
        ),
        IconButton(
          tooltip: '更新当前位置',
          icon: resolving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location_outlined, size: 21),
          onPressed: resolving ? null : onRefresh,
        ),
      ],
    );
  }
}

class _DestinationField extends StatelessWidget {
  const _DestinationField({
    required this.controller,
    required this.searching,
    required this.suggestions,
    required this.searchError,
    required this.searchEnabled,
    required this.unavailableHint,
    required this.onChanged,
    required this.onSelected,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool searching;
  final List<PlaceSuggestion> suggestions;
  final String? searchError;
  final bool searchEnabled;
  final String unavailableHint;
  final ValueChanged<String> onChanged;
  final ValueChanged<PlaceSuggestion> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: TextField(
            controller: controller,
            enabled: searchEnabled,
            onChanged: onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: searchEnabled ? '搜索目的地' : unavailableHint,
              prefixIcon: const Icon(Icons.flag_outlined, size: 20),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (controller.text.isNotEmpty
                        ? IconButton(
                            tooltip: '清除终点',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: onClear,
                          )
                        : null),
            ),
          ),
        ),
        if (searchError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                searchError!,
                style: AppText.caption.copyWith(color: AppColors.danger),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
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
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: Center(
          child: CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.accentMuted,
            child: Text(
              '$index',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ),
        ),
      ),
      title: Text(
        suggestion.name,
        style: AppText.body,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: '移除途经点',
        icon: const Icon(Icons.close, size: 18),
        onPressed: onRemove,
      ),
    );
  }
}

class _RouteResult extends ConsumerWidget {
  const _RouteResult({required this.route, required this.formatter});

  final Route route;
  final UnitFormatter formatter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isStraightLine = route.provider == 'offline';
    final elevationEnabled = ref.watch(currentSettingsProvider).routeElevation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text('规划结果', style: AppText.sectionTitle),
        ),
        if (isStraightLine)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: _Notice(
              icon: Icons.warning_amber_outlined,
              text: '这是直线路径，不是真实骑行路线。配置高德 Key 后可获得沿道路的骑行导航。',
              tone: _NoticeTone.warning,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('路线指引', style: AppText.body),
              subtitle: Text(
                '${route.instructions.length} 个转向提示',
                style: AppText.caption,
              ),
              children: [
                for (final instruction in route.instructions)
                  _InstructionRow(instruction: instruction),
              ],
            ),
          ),
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
