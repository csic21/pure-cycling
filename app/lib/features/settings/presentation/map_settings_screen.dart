import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/map/map_providers.dart';
import '../../../core/map/tile_cache.dart';
import '../../../core/sync/functions_config.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../domain/app_settings.dart';

/// Map service configuration (spec §10, §51).
///
/// The AMap key lives here rather than in the settings database proper because
/// it is a credential, not a preference: it is never uploaded during sync and
/// never written into a GPX file. Distributed builds use the server relay and
/// hide the local-key controls; self-use builds can still supply a key here.
class MapSettingsScreen extends ConsumerStatefulWidget {
  const MapSettingsScreen({super.key});

  @override
  ConsumerState<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends ConsumerState<MapSettingsScreen> {
  late final TextEditingController _keyController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(
      text: ref.read(amapKeyProvider).valueOrNull ?? '',
    );
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(currentSettingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final services = ref.watch(mapServicesProvider);
    final trafficLights = services.trafficLights;

    return Scaffold(
      appBar: AppBar(title: const Text('地图')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '地图显示',
            rows: [
              SettingsChoice<MapStyle>(
                title: '地图风格',
                subtitle: services.tileSource.darkAvailable
                    ? null
                    : '高德栅格图只有浅色样式，应用会自动压暗以适应 OLED 屏幕',
                value: settings.mapStyle,
                options: [
                  for (final style in MapStyle.values)
                    (value: style, label: style.label),
                ],
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(mapStyle: v)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  '当前瓦片源：${services.tileSource.name}'
                  '（${services.tileSource.datum == MapDatum.gcj02 ? 'GCJ-02 国测局坐标' : 'WGS-84'}）',
                  style: AppText.caption,
                ),
              ),
            ],
          ),

          SettingsSection(
            title: '路线规划',
            rows: [
              if (FunctionsConfig.routeUrl != null)
                SettingsTile(
                  title: services.routes.isConfigured
                      ? '使用服务端路线规划'
                      : '登录后可使用在线骑行路线',
                  subtitle: '高德 Key 由运营方在服务端配置，骑手无需填写；匿名账号也可以使用。',
                  leading: const Icon(Icons.route_outlined),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: _keyController,
                    decoration: const InputDecoration(
                      labelText: '高德 Web 服务 Key',
                      hintText: '32 位十六进制字符串',
                      helperText: '需要「Web 服务」类型的 Key，不是 Android/iOS SDK Key',
                      helperMaxLines: 2,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: FilledButton(
                    onPressed: _saving ? null : _saveKey,
                    child: Text(_saving ? '保存中…' : '保存并使用'),
                  ),
                ),
                if (services.routes.isConfigured)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: OutlinedButton(
                      onPressed: _clearKey,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: const BorderSide(color: AppColors.hairline),
                      ),
                      child: const Text('清除 Key，改用直线路径'),
                    ),
                  ),
              ],
            ],
            footnote: FunctionsConfig.routeUrl != null
                ? '未登录时使用直线路径；在线规划需要会话，并受每日调用额度限制。'
                : '不填写也可以正常记录骑行、使用码表和历史记录，路线规划会退化为直线，'
                      '并会明确标注。这个 Key 属于 App 的运营方（自用时就是你自己）；'
                      '如果 App 是别人分发给你的，不需要填这里。',
          ),

          SettingsSection(
            title: '红绿灯倒计时',
            rows: [
              SettingsTile(
                title: trafficLights.isAvailable ? '可用' : '不可用',
                subtitle: trafficLights.unavailableReason,
                leading: const Icon(Icons.traffic_outlined),
              ),
            ],
            footnote:
                '红绿灯倒计时通过高德两轮车导航 SDK 提供，需要单独的授权与商务确认，'
                '当前版本没有接入。这是一个增强能力，不影响记录与导航。',
          ),

          SettingsSection(
            title: '路线海拔',
            rows: [
              SettingsSwitch(
                title: '查询路线高程',
                subtitle: settings.routeElevation
                    ? '已开启：规划好的路线会发往公开高程服务，用于计算爬升和海拔剖面'
                    : '已关闭：路线的爬升显示为 —，因为高德算路不返回海拔',
                value: settings.routeElevation,
                onChanged: (v) =>
                    notifier.mutate((s) => s.copyWith(routeElevation: v)),
              ),
            ],
            footnote:
                '高程数据来自 OpenTopoData 的公开 SRTM 30m 数据集（无需 Key）。'
                '开启意味着**路线的坐标**会发送给这个第三方服务 —— 这是本 App 里'
                '唯一一处会把你的坐标发给非地图供应商的地方，所以默认关闭。'
                '30 米分辨率能看清坡和垭口，看不清桥和隧道口。',
          ),

          const _TileCacheSection(),

          SettingsSection(
            title: '地理编码',
            rows: [
              SettingsTile(
                title: 'POI 搜索',
                subtitle: services.places.isConfigured ? '可用' : '需要配置 Key',
                leading: const Icon(Icons.search),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveKey() async {
    setState(() => _saving = true);

    final key = _keyController.text.trim();
    final store = ref.read(settingsRepositoryProvider);
    if (key.isEmpty) {
      await store.setString('amap_key', '');
    } else {
      await store.setString('amap_key', key);
    }

    ref.invalidate(amapKeyProvider);
    // The key provider is async, so the derived map-services provider has to be
    // invalidated too — otherwise the app keeps the old provider until the next
    // restart, and the rider concludes the key did not work.
    await ref.read(amapKeyProvider.future);

    if (!mounted) return;
    setState(() => _saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(key.isEmpty ? '已清除 Key，路线规划将使用直线' : '已保存，路线规划将使用高德骑行路线'),
      ),
    );
  }

  Future<void> _clearKey() async {
    _keyController.clear();
    await _saveKey();
  }
}

/// What the map has kept on disk, and a way to throw it away.
///
/// Worth a section of its own for two reasons. It is the difference between a
/// tunnel being a blank screen and a tunnel being the road the rider already
/// looked at; and the cache is a record of where they have been looking — a
/// location trace by another name. Anything that sensitive gets to be visible
/// and clearable rather than an invisible side effect of opening the map.
class _TileCacheSection extends ConsumerStatefulWidget {
  const _TileCacheSection();

  @override
  ConsumerState<_TileCacheSection> createState() => _TileCacheSectionState();
}

class _TileCacheSectionState extends ConsumerState<_TileCacheSection> {
  static const TileCache _cache = TileCache();

  ({int bytes, int tiles})? _size;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final size = await _cache.measure();
    if (mounted) setState(() => _size = size);
  }

  @override
  Widget build(BuildContext context) {
    final size = _size;
    final bytes = size?.bytes ?? 0;

    return SettingsSection(
      title: '离线瓦片',
      rows: [
        SettingsTile(
          title: '已缓存的地图',
          subtitle: size == null
              ? '正在统计…'
              : bytes == 0
              ? '暂无缓存。打开地图后，看过的区域会留在本机'
              : '${_formatBytes(bytes)} · ${size.tiles} 张。'
                    '看过的区域断网后仍能显示',
          leading: const Icon(Icons.map_outlined),
        ),
        if (bytes > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: OutlinedButton(
              onPressed: () => _confirmClear(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.hairline),
              ),
              child: const Text('清空缓存'),
            ),
          ),
      ],
      footnote:
          '缓存最多占用 1 GB，系统也可能自行清理。它按你实际看过的区域记录，'
          '本身就是一个位置线索，所以随时可以清空；清空不影响骑行记录。',
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空离线瓦片？'),
        content: const Text(
          '删除本机缓存的地图图片。骑行记录、路线和 GPX 都不受影响；'
          '下次打开地图时会重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _cache.clear();
    await _measure();
  }

  static String _formatBytes(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
