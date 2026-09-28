import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'github_release_checker.dart';

const _lastCheckKey = 'github_release_last_check';

/// Checks the public release feed. Automatic checks are quiet when offline and
/// happen at most once per day; the About screen always performs a fresh check.
Future<void> checkForAppUpdate(
  BuildContext context, {
  bool automatic = false,
}) async {
  SharedPreferences? preferences;
  try {
    preferences = await SharedPreferences.getInstance();
    if (automatic) {
      final last = preferences.getInt(_lastCheckKey);
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              const Duration(hours: 24).inMilliseconds) {
        return;
      }
    }

    final installed = (await PackageInfo.fromPlatform()).version;
    final checker = GitHubReleaseChecker();
    AppRelease? release;
    try {
      release = await checker.check(installedVersion: installed);
    } finally {
      checker.close();
    }
    await preferences.setInt(
      _lastCheckKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    if (!context.mounted) return;

    if (release == null) {
      if (!automatic) _message(context, '已经是最新版本');
      return;
    }

    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final downloadUrl = isAndroid ? release.androidApkUrl : null;
    if (automatic && isAndroid && downloadUrl == null) return;
    final notes = release.notes.length > 800
        ? '${release.notes.substring(0, 800)}…'
        : release.notes;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 ${release!.version}'),
        content: SingleChildScrollView(
          child: Text(
            [
              if (notes.isNotEmpty) notes,
              if (isAndroid && downloadUrl == null) '此版本尚未提供 Android 安装包。',
              if (!isAndroid) '请通过当前安装渠道更新；GitHub 页面可查看版本说明。',
            ].join('\n\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                final opened = await launchUrl(
                  downloadUrl ?? release!.pageUrl,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  _message(context, '无法打开更新页面');
                }
              } catch (_) {
                if (context.mounted) _message(context, '无法打开更新页面');
              }
            },
            child: Text(downloadUrl == null ? '查看 Release' : '下载更新'),
          ),
        ],
      ),
    );
  } on ReleaseCheckException catch (error) {
    if (!automatic && context.mounted) _message(context, error.message);
  } catch (_) {
    if (!automatic && context.mounted) _message(context, '检查更新失败，请稍后重试');
  }
}

void _message(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
