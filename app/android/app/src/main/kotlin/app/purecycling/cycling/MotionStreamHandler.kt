package app.purecycling.cycling

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel
import kotlin.math.sqrt

/**
 * The phone's accelerometer, as a stream of acceleration magnitudes in g.
 *
 * Magnitude rather than three axes, and that is the contract rather than an
 * economy: the only thing downstream needs is vibration energy, and the
 * magnitude is the one form of it that does not depend on how the phone is
 * oriented. A phone lying flat, on its side in a jersey pocket or clamped in a
 * stem mount gives the same number for the same road.
 *
 * What it deliberately does *not* do is decide whether the bike is moving.
 * That lives in Dart (`core/location/motion_detector.dart`): it is arithmetic
 * with a right answer, and testing it against synthetic signatures is the only
 * way to know the thresholds are sane before standing on a bicycle.
 *
 * `TYPE_ACCELEROMETER` needs no permission.
 */
class MotionStreamHandler(context: Context) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensor = accelerometer
        if (sensor == null) {
            // Not a failure: the app records fine without one, and every
            // consumer falls back to GPS speed. Dart reads this as "no motion
            // sensor" and leaves auto-pause exactly as it was.
            events.error("unavailable", "no accelerometer on this device", null)
            return
        }

        sink = events
        // UI rate — around 15 Hz. This is a vibration measurement, not a
        // gesture: the window in Dart is a second and a half wide, and a
        // faster stream would spend battery to measure the same road.
        sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        val x = event.values[0].toDouble()
        val y = event.values[1].toDouble()
        val z = event.values[2].toDouble()

        // Metres per second squared to g, so the threshold in Dart means one
        // thing on both platforms. iOS reports g natively.
        val magnitude = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
        if (!magnitude.isFinite()) return

        sink?.success(magnitude)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // An accelerometer's accuracy is not actionable here: the sensor
        // either reports or it does not, and the detector judges the readings
        // by their own spread rather than by this flag.
    }
}
