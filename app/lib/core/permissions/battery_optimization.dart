import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Whether Android is allowed to defer this app to save battery.
///
/// A ride recorder dies quietly under that deferral: the location stream
/// stops, the screen still says the ride is running, and the rider finds out
/// from a straight line on the map. The system dialog is the supported way
/// to opt this package out. iOS has no equivalent switch, and a desktop
/// build must not ask a plugin that is not there.
class BatteryOptimization {
  const BatteryOptimization();

  bool get applies => defaultTargetPlatform == TargetPlatform.android;

  /// Unknown counts as already ignored: nagging somebody whose platform did
  /// not answer is worse than staying quiet.
  Future<bool> isIgnoring() async {
    if (!applies) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Opens the system dialog that exempts this app. Returns whether the
  /// exemption is now in place.
  Future<bool> request() async {
    if (!applies) return true;
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }
}
