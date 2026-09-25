import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../core/map/map_providers.dart';
import '../../../shared/widgets/settings_widgets.dart';
import '../domain/app_settings.dart';

/// Map service configuration (spec §10, §51).
///
/// The AMap key lives here rather than in the settings database proper because
/// it is a credential, not a preference: it is never uploaded during sync and
/// never written into a GPX file. Everything that talks to AMap goes through
/// the provider abstraction in `core/map`, so entering a key here is the only
/// step needed to turn real cycling routes on.
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
                onChanged: (v) => notifier.mutate((s) => s.copyWith(mapStyle: v)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
            footnote: '不填写也可以正常记录骑行、使用码表和历史记录，路线规划会退化为直线，'
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
            footnote: '红绿灯倒计时通过高德两轮车导航 SDK 提供，需要单独的授权与商务确认，'
                '当前版本没有接入。这是一个增强能力，不影响记录与导航。',
          ),

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
        content: Text(
          key.isEmpty
              ? '已清除 Key，路线规划将使用直线'
              : '已保存，路线规划将使用高德骑行路线',
        ),
      ),
    );
  }

  Future<void> _clearKey() async {
    _keyController.clear();
    await _saveKey();
  }
}
