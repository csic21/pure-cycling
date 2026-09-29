import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// System bars belong to the ride route, not to the recording session: a deep
/// link can leave the route while recording continues in the background.
abstract final class RideFullscreen {
  static const MethodChannel _androidChannel = MethodChannel(
    'app.purecycling/ride_fullscreen',
  );

  static Future<void> enter() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // Flutter's legacy SystemUiMode flags are ignored by Android 15/16
        // edge-to-edge enforcement. The activity uses WindowInsetsController.
        await _androidChannel.invokeMethod<void>('setImmersive', true);
      case TargetPlatform.iOS:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        break;
    }
  }

  static Future<void> exit() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        await _androidChannel.invokeMethod<void>('setImmersive', false);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      case TargetPlatform.iOS:
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        break;
    }
  }
}
