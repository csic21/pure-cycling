import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme.dart';
import '../../../../app/providers.dart';
import '../../../../core/location/location_service.dart';

/// Device-local flags for the two permission notices.
///
/// Public so the app, the settings screen and the tests all reason about the
/// same strings. Kept in the KV table rather than in `AppSettings` on purpose:
/// a permission grant belongs to *this phone*, and syncing the flag to another
/// device would skip a notice that device has never seen.
abstract final class LocationNoticeKeys {
  static const String disclosureSeen = 'location_disclosure_seen';
  static const String backgroundHintSeen = 'background_location_hint_seen';

  /// Set when the recording-notification request has been made once. Asking
  /// again every ride is how a permission prompt becomes something riders
  /// tap through without reading.
  static const String notificationAsked = 'notification_asked';

  static const String seen = 'true';
}

/// The explanation that comes before the system permission dialog.
///
/// Two reasons this exists, and they point the same way:
///
/// * **Play requires it.** An app that asks for background location has to
///   disclose what it is for, in the app, before the OS dialog appears — the
///   dialog alone is not accepted as disclosure.
/// * **The rider deserves it.** The next thing they see is a system sheet
///   asking for location 「始终允许」, which reads as invasive unless somebody
///   has said why. A bike computer that stops recording when the phone goes
///   into a pocket is not a bike computer.
///
/// Returns true when the rider agreed to continue. Declining is a real option:
/// the app records with the screen on, and nothing is lost by waiting.
Future<bool> showLocationDisclosure(BuildContext context) async {
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('为什么需要「始终允许」定位', style: AppText.title),
            const SizedBox(height: 14),
            const _Point(
              icon: Icons.lock_clock,
              text:
                  '锁屏后还要继续记录。骑行时手机在口袋里，'
                  '系统只允许「始终允许」的应用在后台持续获取位置。',
            ),
            const SizedBox(height: 12),
            const _Point(
              icon: Icons.phone_android,
              text:
                  '只在使用这个 App 记录骑行时获取位置，'
                  '不会在其它时间读取。',
            ),
            const SizedBox(height: 12),
            const _Point(
              icon: Icons.shield_outlined,
              text:
                  '轨迹默认只保存在本机。打开云同步后才会上传到你的账号，'
                  '没有任何人能公开看到。',
            ),
            const SizedBox(height: 12),
            const _Point(
              icon: Icons.do_not_disturb_alt,
              text: '不读取通讯录，不获取广告标识。',
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              child: const Text('继续'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext, false),
              child: const Text('先不开，我等会儿再骑'),
            ),
          ],
        ),
      ),
    ),
  );

  return agreed ?? false;
}

/// Says the quiet part out loud: this phone only granted location 「使用期间」,
/// so a ride can stop when the screen goes off.
///
/// Shown once, and never as a blocker — the rider can keep riding with the
/// screen on, which is a legitimate way to use the app.
Future<bool> showBackgroundLocationHint(BuildContext context) async {
  final request = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('锁屏后记录可能中断', style: AppText.title),
            const SizedBox(height: 10),
            const Text(
              '这台手机目前只允许「使用 App 期间」定位。屏幕熄灭后系统可能不再'
              '提供位置，记录会停止 —— 而骑手通常是骑完才发现的。\n\n'
              '开启「始终允许」定位，锁屏时才能继续记录轨迹。你也可以暂时只在屏幕亮着时骑行。',
              style: AppText.caption,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              child: const Text('开启始终允许'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext, false),
              child: const Text('暂时继续'),
            ),
          ],
        ),
      ),
    ),
  );
  return request ?? false;
}

/// Requests location at the point where the rider starts recording. Route
/// navigation and a free ride use the same flow, before creating a session.
Future<bool> prepareRideLocation(BuildContext context, WidgetRef ref) async {
  final store = ref.read(settingsRepositoryProvider);
  final location = ref.read(locationServiceProvider);

  if (await store.getString(LocationNoticeKeys.disclosureSeen) !=
      LocationNoticeKeys.seen) {
    if (!context.mounted) return false;
    if (!await showLocationDisclosure(context) || !context.mounted) {
      return false;
    }
    await store.setString(
      LocationNoticeKeys.disclosureSeen,
      LocationNoticeKeys.seen,
    );
  }

  // The first system prompt asks for foreground access only. In particular,
  // Android requires this grant before background location can be requested.
  final permission = await location.ensurePermission(requestBackground: false);
  if (!context.mounted) return false;
  if (!permission.isUsable) {
    await showLocationPermissionProblem(context, location, permission);
    return false;
  }

  if (!await location.hasBackgroundAccess() &&
      await store.getString(LocationNoticeKeys.backgroundHintSeen) !=
          LocationNoticeKeys.seen) {
    if (!context.mounted) return false;
    final request = await showBackgroundLocationHint(context);
    await store.setString(
      LocationNoticeKeys.backgroundHintSeen,
      LocationNoticeKeys.seen,
    );
    if (request) {
      // A foreground-only choice is still enough to start a ride. The hint
      // explains the screen-off limitation before the rider makes that choice.
      await location.ensurePermission(requestBackground: true);
    }
  }

  // Warm GNSS now, while the rider is still on the home screen / navigating
  // into the ride. The countdown then waits on a chip that is already locking
  // rather than paying cold TTFF on the bars. Foreground-only: no FGS yet.
  // Cancelled when the ride subscription opens or the ride is abandoned.
  if (context.mounted) {
    final mode = ref.read(currentSettingsProvider).gpsAccuracy;
    unawaited(location.prewarm(mode: mode));
  }

  return context.mounted;
}

Future<void> showLocationPermissionProblem(
  BuildContext context,
  LocationService location,
  LocationPermissionStatus permission,
) async {
  final (title, message, actionLabel, action) = switch (permission) {
    LocationPermissionStatus.serviceDisabled => (
      '系统定位服务未开启',
      '请打开系统设置中的「定位服务」后重试。',
      '打开设置',
      location.openLocationSettings,
    ),
    LocationPermissionStatus.deniedForever => (
      '定位权限已被拒绝',
      '请在系统设置中允许「纯粹骑行」使用定位，然后重试。',
      '打开设置',
      location.openAppSettings,
    ),
    _ => ('需要定位权限', '记录轨迹或使用当前位置需要定位权限。请允许定位后重试。', '知道了', null),
  };
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        if (action != null)
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            if (action != null) action();
          },
          child: Text(actionLabel),
        ),
      ],
    ),
  );
}

/// Asks for the recording notification, in the app, before the system dialog.
///
/// Same two reasons as the location disclosure: Play expects the app to say
/// why before it asks, and the rider deserves to know what they are agreeing
/// to. What is worth saying here is that the notification is not chatter —
/// once the screen locks, it is the only evidence that the ride is still being
/// recorded.
///
/// Returns true when the rider agreed to the system dialog.
Future<bool> showNotificationNotice(BuildContext context) async {
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('记录时显示一条通知', style: AppText.title),
            const SizedBox(height: 14),
            const _Point(
              icon: Icons.notifications_none,
              text:
                  '骑行过程中通知栏会常驻一条「正在记录骑行」。'
                  '锁屏之后，它是你确认记录还在继续的唯一方式。',
            ),
            const SizedBox(height: 12),
            const _Point(
              icon: Icons.battery_charging_full,
              text:
                  '不影响记录本身。即使不允许，骑行照常保存，'
                  '只是锁屏后看不到这条状态。',
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              child: const Text('允许通知'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext, false),
              child: const Text('不用通知'),
            ),
          ],
        ),
      ),
    ),
  );

  return agreed ?? false;
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.accent),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: AppText.body)),
      ],
    );
  }
}
