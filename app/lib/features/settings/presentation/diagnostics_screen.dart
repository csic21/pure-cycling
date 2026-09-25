import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/widgets/settings_widgets.dart';

/// The diagnostic log, and the two things anyone can do with it.
///
/// It exists because the honest alternative to a crash-reporting SDK is a file
/// the rider can hand over. That makes this screen the whole support story:
/// if it does not make the file easy to produce, the log may as well not
/// exist — on iOS the rider has no other way to reach it.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  int? _sizeBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final size = await ref.read(diagnosticLogProvider).sizeBytes();
    if (mounted) setState(() => _sizeBytes = size);
  }

  @override
  Widget build(BuildContext context) {
    final size = _sizeBytes;

    return Scaffold(
      appBar: AppBar(title: const Text('诊断日志')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsSection(
            title: '记录了什么',
            rows: const [
              SettingsTile(
                title: '只记录异常和堆栈',
                subtitle: '应用出错时写下错误信息和调用栈，并标明来源。'
                    '不记录位置、轨迹或任何骑行数据，也不会自动上传到任何地方。',
                leading: Icon(Icons.description_outlined),
              ),
              SettingsTile(
                title: '不包含电池与设备信息',
                subtitle: '没有广告标识、没有设备指纹。'
                    '日志文件最多保留最近的 256 KB，旧的会被丢弃。',
                leading: Icon(Icons.memory_outlined),
              ),
            ],
          ),
          SettingsSection(
            title: '当前日志',
            rows: [
              SettingsTile(
                title: size == null
                    ? '正在读取…'
                    : size == 0
                        ? '还没有记录'
                        : '${(size / 1024).toStringAsFixed(1)} KB',
                subtitle: size == 0
                    ? '没有出错时这里是空的，这是正常的。'
                    : '导出发给运营方即可定位问题。',
                leading: const Icon(Icons.folder_outlined),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: FilledButton.icon(
              onPressed: _busy || size == null || size == 0 ? null : _export,
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('导出日志'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: OutlinedButton(
              onPressed: _busy || size == null || size == 0
                  ? null
                  : () => _confirmClear(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.hairline),
              ),
              child: const Text('清空日志'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final log = ref.read(diagnosticLogProvider);
      final content = await log.read();
      if (content.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导出的内容')),
        );
        return;
      }

      final file = File(
        '${Directory.systemTemp.path}/purecycling-diagnostic.log',
      );
      await file.writeAsString(content, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          subject: '纯粹骑行 诊断日志',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空诊断日志？'),
        content: const Text('只删除这份日志，骑行记录不受影响。'),
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
    await ref.read(diagnosticLogProvider).clear();
    await _refresh();
  }
}
