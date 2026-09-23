import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../app/router.dart';
import '../../../app/theme.dart';
import '../../../core/gpx/gpx_codec.dart';
import '../../../core/map/map_providers.dart';
import '../../../core/utils/units.dart';
import '../../../shared/widgets/elevation_chart.dart';
import '../../../shared/widgets/route_map.dart';
import '../data/route_repository.dart';

/// GPX import (spec §3, §2.1).
///
/// Three ways in, because riders get GPX files three different ways: from the
/// file system, from another app via the clipboard, and from a link someone
/// sent them.
///
/// The preview step is not decoration. A GPX file is opaque until you look at
/// it — whether it is a ride, a planned route, or a mis-exported hike is not
/// visible from the filename — so the screen parses, shows the shape and the
/// numbers, and only then offers to save.
class GpxImportScreen extends ConsumerStatefulWidget {
  const GpxImportScreen({super.key});

  @override
  ConsumerState<GpxImportScreen> createState() => _GpxImportScreenState();
}

class _GpxImportScreenState extends ConsumerState<GpxImportScreen> {
  ParsedGpx? _parsed;

  /// The original file text, kept so saving re-parses the same bytes the
  /// preview was built from.
  String? _rawContent;

  String? _error;
  String? _sourceName;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final formatter = ref.watch(unitFormatterProvider);
    final tileSource = ref.watch(mapServicesProvider).tileSource;

    return Scaffold(
      appBar: AppBar(title: const Text('导入 GPX')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _SourceButton(
                  icon: Icons.folder_open_outlined,
                  title: '从文件中选择',
                  subtitle: '选择手机中的 .gpx 文件',
                  onTap: _busy ? null : _pickFile,
                ),
                _SourceButton(
                  icon: Icons.content_paste_outlined,
                  title: '从剪贴板粘贴',
                  subtitle: '适用于从聊天或网页复制的 GPX 内容',
                  onTap: _busy ? null : _pasteFromClipboard,
                ),

                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: AppColors.danger.withValues(alpha: 0.4),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: AppText.caption
                                  .copyWith(color: AppColors.danger),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_parsed != null) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  _Preview(
                    parsed: _parsed!,
                    sourceName: _sourceName,
                    formatter: formatter,
                    tileSource: tileSource,
                  ),
                ],
              ],
            ),
          ),
          if (_parsed != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存为路线'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gpx', 'xml'],
        dialogTitle: '选择 GPX 文件',
      );

      if (files.isEmpty) {
        setState(() => _busy = false);
        return;
      }

      final file = files.first;
      // Read through `readAsBytes` rather than a path: on iOS and on Android
      // with a content:// URI the picked file is a temporary copy that may
      // already be gone by the time a path is opened.
      final bytes = await file.readAsBytes();
      _parse(utf8.decode(bytes, allowMalformed: true), file.name);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '读取文件失败：$e';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;

    if (text == null || text.trim().isEmpty) {
      setState(() {
        _busy = false;
        _error = '剪贴板里没有文本内容';
      });
      return;
    }

    _parse(text, '剪贴板');
  }

  void _parse(String content, String sourceName) {
    try {
      final parsed = GpxCodec.decode(content);
      if (parsed.isEmpty) {
        setState(() {
          _busy = false;
          _error = '这个文件里没有足够的轨迹点（至少需要 2 个）。'
              '它可能是一个路点列表，而不是一条轨迹。';
        });
        return;
      }
      setState(() {
        _parsed = parsed;
        _rawContent = content;
        _sourceName = sourceName;
        _busy = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '无法解析这个文件，可能不是有效的 GPX：$e';
      });
    }
  }

  Future<void> _save() async {
    final parsed = _parsed;
    final content = _rawContent;
    if (parsed == null || content == null) return;

    setState(() => _busy = true);

    try {
      // The repository does its own parse rather than accepting the one
      // already held here: it is the single place that decides what a usable
      // GPX is, and two parsers drifting apart is exactly how an import
      // previews correctly and then saves something else.
      final route = await ref.read(routeRepositoryProvider).importGpx(
            content,
            name: parsed.name ?? _sourceName,
          );
      if (!mounted) return;
      context.pushReplacement(AppRoutes.routeDetailFor(route.id));
    } on GpxImportException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '保存失败：$e';
      });
    }
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title, style: AppText.body),
      subtitle: Text(subtitle, style: AppText.caption),
      trailing: const Icon(
        Icons.chevron_right,
        size: 20,
        color: AppColors.textTertiary,
      ),
      onTap: onTap,
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.parsed,
    required this.sourceName,
    required this.formatter,
    required this.tileSource,
  });

  final ParsedGpx parsed;
  final String? sourceName;
  final UnitFormatter formatter;
  final MapTileSource tileSource;

  @override
  Widget build(BuildContext context) {
    final points = parsed.points.map((p) => p.point).toList(growable: false);
    final distance = GpxCodec.lengthMeters(parsed.points);
    final elevation = GpxCodec.elevationProfile(parsed.points);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text(
            parsed.name ?? sourceName ?? '导入的路线',
            style: AppText.title,
          ),
        ),
        SizedBox(
          height: 220,
          child: RouteMap(
            tileSource: tileSource,
            routePoints: points,
            interactive: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Row(
            children: [
              _Stat(
                value: formatter.distanceKm(distance),
                unit: formatter.system.distanceSuffix,
                label: '距离',
              ),
              _Stat(
                value: '${parsed.points.length}',
                unit: '点',
                label: '轨迹点',
              ),
              _Stat(
                value: parsed.points.any((p) => p.elevation != null)
                    ? '有'
                    : '无',
                label: '海拔数据',
              ),
            ],
          ),
        ),
        if (elevation.length > 1) ...[
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ElevationChart(
              samples: elevation,
              formatter: formatter,
              distanceMeters: distance,
            ),
          ),
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
