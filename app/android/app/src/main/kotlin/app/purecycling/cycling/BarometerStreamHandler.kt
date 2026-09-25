package app.purecycling.cycling

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel

/**
 * The phone's own barometer, as a stream of pressure in hPa.
 *
 * Why this is written by hand rather than pulled from pub.dev: the maintained
 * packages for it are either years old and SDK-incompatible, or published
 * under a `com.example` identifier within an hour of each other. It is thirty
 * lines of platform API, and this project already keeps its platform
 * integrations explicit (see the foreground service and the URL scheme).
 *
 * What it deliberately does *not* do is convert pressure to altitude. That
 * lives in Dart (`core/location/barometer_source.dart`), so the arithmetic
 * exists once and is testable without a device.
 */
class BarometerStreamHandler(context: Context) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val pressureSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_PRESSURE)

    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensor = pressureSensor
        if (sensor == null) {
            // Not a failure: plenty of phones have no barometer, and the app
            // is fully usable without one. The Dart side reads this as
            // "no barometer" and leaves the climb figure labelled as an
            // estimate.
            events.error("unavailable", "no barometer on this device", null)
            return
        }

        sink = events
        // NORMAL is a few hertz, which is plenty for terrain and costs the
        // battery almost nothing. The ride's own sampling rate is set by the
        // location stream.
        sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        // TYPE_PRESSURE reports hPa directly.
        sink?.success(event.values[0].toDouble())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // A barometer's accuracy is not actionable here: the reading's own
        // resolution is in the number, and the ride's quality label comes from
        // the vertical accuracy the Dart side assigns to a barometric series.
    }
}
