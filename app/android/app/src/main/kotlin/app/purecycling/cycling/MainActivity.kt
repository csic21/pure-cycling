package app.purecycling.cycling

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {

    private var barometer: BarometerStreamHandler? = null
    private var compass: CompassStreamHandler? = null
    private var motion: MotionStreamHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val barometerHandler = BarometerStreamHandler(this)
        barometer = barometerHandler
        EventChannel(messenger, BAROMETER_CHANNEL).setStreamHandler(barometerHandler)

        val compassHandler = CompassStreamHandler(this)
        compass = compassHandler
        EventChannel(messenger, COMPASS_CHANNEL).setStreamHandler(compassHandler)

        val motionHandler = MotionStreamHandler(this)
        motion = motionHandler
        EventChannel(messenger, MOTION_CHANNEL).setStreamHandler(motionHandler)
    }

    override fun onDestroy() {
        // The sensors must be unregistered with the activity, not left to the
        // process: a listener that outlives its activity is a leak, and on
        // some ROMs a battery complaint.
        barometer?.stop()
        barometer = null
        compass?.stop()
        compass = null
        motion?.stop()
        motion = null
        super.onDestroy()
    }

    companion object {
        /** Must match `PlatformBarometerSource.channelName` on the Dart side. */
        const val BAROMETER_CHANNEL = "app.purecycling/barometer"

        /** Must match `PlatformCompassSource.channelName` on the Dart side. */
        const val COMPASS_CHANNEL = "app.purecycling/compass"

        /** Must match `PlatformMotionSource.channelName` on the Dart side. */
        const val MOTION_CHANNEL = "app.purecycling/motion"
    }
}
