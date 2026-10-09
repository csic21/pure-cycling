import CoreLocation
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
    let messenger = engineBridge.applicationRegistrar.messenger()
    BarometerChannel.register(messenger: messenger)
    CompassChannel.register(messenger: messenger)
    MotionChannel.register(messenger: messenger)
  }
}

/// The phone's accelerometer, as a stream of acceleration magnitudes in g.
///
/// The Android side is the mirror image (`MotionStreamHandler.kt`), and the
/// division of labour is the same: the platform reports a number, and the
/// decision about whether the bike is moving lives in Dart
/// (`core/location/motion_detector.dart`) where it can be tested against
/// synthetic signatures rather than against a bicycle.
///
/// `CMMotionManager` acceleration needs no permission, and
/// `NSMotionUsageDescription` is already present for `CMAltimeter`.
enum MotionChannel {
  static let name = "app.purecycling/motion"

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: name, binaryMessenger: messenger)
      .setStreamHandler(MotionStreamHandler())
  }
}

final class MotionStreamHandler: NSObject, FlutterStreamHandler {
  private let motionManager = CMMotionManager()
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard motionManager.isAccelerometerAvailable else {
      // Not a failure: the app records fine without one, and auto-pause falls
      // back to the speed rule it used before this existed.
      events(FlutterError(code: "unavailable", message: "no accelerometer on this device", details: nil))
      return nil
    }

    sink = events
    // About 16 Hz. This is a vibration measurement over a second and a half
    // window, not a gesture, so a faster stream would spend battery to measure
    // the same road.
    motionManager.accelerometerUpdateInterval = 0.06
    motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let acceleration = data?.acceleration else { return }

      // CoreMotion already reports g, which is the unit the Android side
      // converts to, so the threshold in Dart means one thing on both.
      let magnitude = sqrt(
        acceleration.x * acceleration.x
          + acceleration.y * acceleration.y
          + acceleration.z * acceleration.z
      )
      guard magnitude.isFinite else { return }

      self.sink?(magnitude)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    motionManager.stopAccelerometerUpdates()
    sink = nil
    return nil
  }
}

/// The phone's compass, as an event stream of headings in degrees clockwise
/// from north.
///
/// The Android side is the mirror image (`CompassStreamHandler.kt`). Both
/// report the direction the *top of the display* points relative to magnetic
/// north, aligned to true north by the GPS-course anchor. Neither
/// decides whether to be believed: the fusion with GPS course lives in
/// Dart (`core/location/gps_filter.dart`), where it can be tested without a
/// device.
///
/// No permission is needed and `Info.plist` is untouched. `startUpdatingHeading`
/// does need location services to be enabled, which a ride requires anyway.
enum CompassChannel {
  static let name = "app.purecycling/compass"

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: name, binaryMessenger: messenger)
      .setStreamHandler(CompassStreamHandler())
  }
}

final class CompassStreamHandler: NSObject, FlutterStreamHandler,
  CLLocationManagerDelegate
{
  private let locationManager = CLLocationManager()
  private var sink: FlutterEventSink?
  private var orientationObservers: [NSObjectProtocol] = []
  private var observingOrientation = false
  private var orientationQuarterTurns = 0
  private var orientationChangedAt = Date.distantPast

  override init() {
    super.init()
    locationManager.delegate = self
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard CLLocationManager.headingAvailable() else {
      // Not a failure: iPads and the Wi-Fi-only models have no magnetometer,
      // and the app is fully usable without one. Dart reads this as "no
      // compass" and the direction falls back to the GPS course.
      events(FlutterError(code: "unavailable", message: "no compass on this device", details: nil))
      return nil
    }

    sink = events
    updateHeadingOrientation()
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    observingOrientation = true
    for name in [UIDevice.orientationDidChangeNotification, UIApplication.didBecomeActiveNotification] {
      orientationObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        // Interface rotation follows the device notification; use the actual
        // window orientation, including an OS rotation lock, on the next turn.
        DispatchQueue.main.async { self?.updateHeadingOrientation() }
      })
    }
    locationManager.startUpdatingHeading()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    locationManager.stopUpdatingHeading()
    orientationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    orientationObservers.removeAll()
    if observingOrientation {
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      observingOrientation = false
    }
    sink = nil
    return nil
  }

  func locationManager(
    _ manager: CLLocationManager,
    didUpdateHeading newHeading: CLHeading
  ) {
    updateHeadingOrientation()
    // CLLocation headings are already in headingOrientation's display frame;
    // applying another Dart-side 90-degree correction would rotate twice.
    // Drop queued old-frame samples and an explicitly unreliable compass.
    guard newHeading.timestamp >= orientationChangedAt,
      newHeading.headingAccuracy >= 0,
      newHeading.magneticHeading.isFinite,
      newHeading.magneticHeading >= 0 else { return }

    sink?([
      // This manager intentionally does not run a second location stream.
      // trueHeading requires its own location updates and can remain invalid.
      // Keep one stable magnetic frame; the GPS anchor already aligns it.
      "heading": newHeading.magneticHeading,
      "accuracy": newHeading.headingAccuracy,
      "orientationQuarterTurns": orientationQuarterTurns,
    ] as [String: Any?])
  }

  private func updateHeadingOrientation() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: { $0.isKeyWindow }) })
      else { return }
    let frame: (CLDeviceOrientation, Int)
    // UIInterfaceOrientation's landscape names are opposite to the physical
    // CLDeviceOrientation names. A direct raw-value cast is incorrect.
    switch scene.interfaceOrientation {
    case .portrait: frame = (.portrait, 0)
    case .landscapeRight: frame = (.landscapeLeft, 1)
    case .portraitUpsideDown: frame = (.portraitUpsideDown, 2)
    case .landscapeLeft: frame = (.landscapeRight, 3)
    default: return
    }
    guard locationManager.headingOrientation != frame.0 else { return }
    orientationChangedAt = Date()
    orientationQuarterTurns = frame.1
    locationManager.headingOrientation = frame.0
  }

  func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
    // The figure-of-eight calibration screen is the right prompt when somebody
    // is looking for their way; it is the wrong one to interrupt a descent
    // with. A poorly calibrated magnetometer reports its own accuracy, and the
    // fusion drops readings it cannot stand behind.
    return false
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
