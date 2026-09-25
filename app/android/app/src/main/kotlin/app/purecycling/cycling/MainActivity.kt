package app.purecycling.cycling

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {

    private var barometer: BarometerStreamHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = BarometerStreamHandler(this)
        barometer = handler
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, BAROMETER_CHANNEL)
            .setStreamHandler(handler)
    }

    override fun onDestroy() {
        // The sensor must be unregistered with the activity, not left to the
        // process: a listener that outlives its activity is a leak, and on
        // some ROMs a battery complaint.
        barometer?.stop()
        barometer = null
        super.onDestroy()
    }

    companion object {
        /** Must match `PlatformBarometerSource.channelName` on the Dart side. */
        const val BAROMETER_CHANNEL = "app.purecycling/barometer"
    }
}
