import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'apk_updater.dart';
import 'github_release_checker.dart';
import 'update_coordinator.dart';

const _lastCheckKey = 'github_release_last_check';

final appUpdateCoordinatorProvider = Provider<AppUpdateCoordinator>((ref) {
  final coordinator = AppUpdateCoordinator(loadRelease: _loadRelease);
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

Future<AppRelease?> _loadRelease(bool automatic) async {
  final preferences = await SharedPreferences.getInstance();
  if (automatic) {
    final last = preferences.getInt(_lastCheckKey);
    if (last != null &&
        DateTime.now().millisecondsSinceEpoch - last <
            const Duration(hours: 24).inMilliseconds) {
      return null;
    }
  }
  final installed = (await PackageInfo.fromPlatform()).version;
  final checker = GitHubReleaseChecker();
  try {
    final release = await checker.check(installedVersion: installed);
    await preferences.setInt(
      _lastCheckKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    return release;
  } finally {
    checker.close();
  }
}

/// Every entry point uses the same application-owned coordinator. Captured
/// About contexts must still own their route when an async check completes.
Future<void> checkForAppUpdate(
  BuildContext context, {
  required AppUpdateCoordinator coordinator,
  bool automatic = false,
}) {
  bool canPresent() =>
      context.mounted &&
      (coordinator.hostIsEligible?.call(automatic) ?? false) &&
      (automatic || (ModalRoute.of(context)?.isCurrent ?? false));
  return coordinator.check(
    UpdateRequest(
      automatic: automatic,
      canPresent: canPresent,
      present: (release) => presentAppUpdate(
        context,
        release: release,
        automatic: automatic,
        canPresent: canPresent,
      ),
      message: (message) => _message(context, message),
    ),
  );
}

/// Own each exact DialogRoute. A delayed completion may remove that route,
/// but can never pop a screen or a newer dialog above it.
Future<void> presentAppUpdate(
  BuildContext context, {
  required AppRelease release,
  required bool automatic,
  required bool Function() canPresent,
  ApkUpdater Function()? createUpdater,
  Future<void> Function(File, String)? install,
}) async {
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
  final downloadUrl = isAndroid ? release.androidApkUrl : null;
  if (automatic && isAndroid && downloadUrl == null) return;
  if (!canPresent()) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final notes = release.notes.length > 800
      ? '${release.notes.substring(0, 800)}…'
      : release.notes;
  late DialogRoute<bool> prompt;
  prompt = DialogRoute<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('发现新版本 ${release.version}'),
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
          onPressed: () => _finishRoute(navigator, prompt, false),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () => _finishRoute(navigator, prompt, true),
          child: Text(downloadUrl == null ? '查看 Release' : '安装更新'),
        ),
      ],
    ),
  );
  final accepted = await navigator.push(prompt);
  if (accepted != true || !context.mounted || !canPresent()) return;
  if (downloadUrl == null) {
    try {
      if (!await launchUrl(
        release.pageUrl,
        mode: LaunchMode.externalApplication,
      )) {
        if (context.mounted && canPresent()) _message(context, '无法打开更新页面');
      }
    } catch (_) {
      if (context.mounted && canPresent()) _message(context, '无法打开更新页面');
    }
    return;
  }

  final updater = createUpdater?.call();
  late DialogRoute<Object> download;
  download = DialogRoute<Object>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ApkDownloadDialog(
      url: downloadUrl,
      updater: updater,
      onComplete: (result) {
        final ownsTop = download.isCurrent;
        _finishRoute(navigator, download, ownsTop ? result : null);
        if (!ownsTop && result is File) unawaited(_discardFile(result));
      },
    ),
  );
  final result = await navigator.push(download);
  if (result == null) return;
  if (result is File) {
    if (!context.mounted || !canPresent()) {
      await _discardFile(result);
      return;
    }
    try {
      await (install ??
          (file, version) => ApkUpdater.install(
            file,
            expectedVersion: version,
          ))(result, release.version);
    } on ApkUpdateException catch (error) {
      if (context.mounted && canPresent()) _message(context, error.message);
    }
  } else if (result is ApkUpdateException && context.mounted && canPresent()) {
    _message(context, result.message);
  }
}

Future<void> _discardFile(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // The next cache sweep retries a temporarily locked abandoned package.
  }
}

void _finishRoute<T>(NavigatorState navigator, Route<T> route, T? result) {
  if (navigator.mounted && route.isActive) {
    navigator.removeRoute<T>(route, result);
  }
}

class ApkDownloadDialog extends StatefulWidget {
  const ApkDownloadDialog({
    super.key,
    required this.url,
    required this.onComplete,
    this.updater,
  });

  final Uri url;
  final void Function(Object? result) onComplete;
  final ApkUpdater? updater;

  @override
  State<ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<ApkDownloadDialog> {
  late final _updater = widget.updater ?? ApkUpdater();
  int _received = 0;
  int? _total;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_download());
  }

  Future<void> _download() async {
    try {
      final file = await _updater.download(
        widget.url,
        onProgress: (received, total) {
          if (!mounted || _finished) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted || _finished) {
        await _discardFile(file);
      } else {
        _complete(file);
      }
    } on ApkUpdateCancelled {
      // Close/Back cancels transport and disk work. No error toast or install.
    } on ApkUpdateException catch (error) {
      if (mounted && !_finished) _complete(error);
    }
  }

  void _complete(Object? result) {
    if (_finished) return;
    _finished = true;
    widget.onComplete(result);
  }

  @override
  void dispose() {
    _finished = true;
    _updater.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == null ? null : _received / _total!;
    final receivedMb = (_received / 1024 / 1024).toStringAsFixed(1);
    final totalMb = _total == null
        ? ''
        : ' / ${(_total! / 1024 / 1024).toStringAsFixed(1)} MB';
    return AlertDialog(
      title: const Text('正在下载更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 12),
          Text('$receivedMb MB$totalMb'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _updater.close();
            _complete(null);
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}

void _message(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
