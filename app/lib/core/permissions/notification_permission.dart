import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// The Android 13+ grant that keeps the recording notification visible.
///
/// It matters more than a notification normally would: while a ride is being
/// recorded, that notification is the only place the rider can see that
/// recording is still alive — after the screen is locked there is nothing else
/// to look at. Android gives apps targeting 33+ no notification at all until
/// they ask, so without this the app records silently.
///
/// Behind a boundary like every other platform API in this project: the home
/// screen asks a yes/no question, and a test answers it without a plugin.
///
/// iOS needs nothing. The blue background-location bar belongs to the system,
/// not to the app, and there is no equivalent runtime grant.
class NotificationPermission {
  const NotificationPermission();

  bool get _needsGrant =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Unknown counts as granted: nagging somebody whose platform did not answer
  /// is worse than staying quiet.
  Future<bool> isGranted() async {
    if (!_needsGrant) return true;
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system dialog. Returns whether it was granted.
  Future<bool> request() async {
    if (!_needsGrant) return true;
    try {
      return (await Permission.notification.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// For a rider who said no and changed their mind. The permission dialog
  /// cannot be shown twice, so the only way back is the app's settings page.
  Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
