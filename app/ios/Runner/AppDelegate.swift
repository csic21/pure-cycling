import CoreMotion
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    BarometerChannel.register(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// The phone's barometer, as an event stream of pressure in hPa.
///
/// The Android side is the mirror image (`BarometerStreamHandler.kt`), and the
/// Dart layer converts pressure to an altitude delta so that arithmetic exists
/// once and is testable without a device.
enum BarometerChannel {
  static let name = "app.purecycling/barometer"

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: name, binaryMessenger: messenger)
      .setStreamHandler(BarometerStreamHandler())
  }
}

final class BarometerStreamHandler: NSObject, FlutterStreamHandler {
  private let altimeter = CMAltimeter()
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard CMAltimeter.isRelativeAltitudeAvailable() else {
      // Not a failure: iPads and some iPhones have no barometer, and the app
      // is fully usable without one. Dart reads this as "no barometer".
      events(FlutterError(code: "unavailable", message: "no barometer on this device", details: nil))
      return nil
    }

    sink = events
    altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
      guard let self = self else { return }

      if let error = error {
        // The usual cause is the Motion & Fitness permission being refused.
        // Reported so the Dart side stops expecting readings; nothing else in
        // the app changes.
        self.sink?(FlutterError(
          code: "altimeter",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }

      guard let data = data else { return }
      // `CMAltitudeData.pressure` is in kPa; the contract is hPa.
      // `relativeAltitude` is deliberately unused: it is the same information
      // computed a second time, and one implementation of the conversion is
      // the one that can be tested.
      self.sink?(data.pressure.doubleValue * 10.0)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    altimeter.stopRelativeAltitudeUpdates()
    sink = nil
    return nil
  }
}
