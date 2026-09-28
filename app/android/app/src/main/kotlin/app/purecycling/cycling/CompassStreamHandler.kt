package app.purecycling.cycling

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel

/**
 * The phone's own compass, as a stream of headings in degrees clockwise from
 * north.
 *
 * Why this is written by hand rather than pulled from pub.dev: the same
 * reasoning as the barometer next door — the maintained packages for it are
 * either years old and SDK-incompatible, or published under a `com.example`
 * identifier. It is a hundred lines of platform API, and this project already
 * keeps its platform integrations explicit.
 *
 * ## What it reports, and what it deliberately does not
 *
 * The heading of the **device's +Y axis** — the top of the phone, the edge the
 * rider reads the numbers from. On handlebars that is the direction of travel,
 * which is the only case this app is for; the phone being in a pocket is
 * handled upstream by refusing to trust a compass more than the GPS course it
 * is standing in for.
 *
 * It does **not** smooth, filter, or decide whether to be believed. That is
 * the interesting part, it has a right answer that can be tested without a
 * device, and it lives in Dart (`core/location/gps_filter.dart`).
 *
 * Neither `TYPE_ROTATION_VECTOR` nor the accelerometer/magnetometer fallback
 * needs any permission.
 */
class CompassStreamHandler(context: Context) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    /**
     * The fused gyroscope/accelerometer/magnetometer sensor. Present on every
     * phone with a magnetometer, and already tilt-compensated — which the
     * accelerometer + magnetometer pair is not, and a phone on a stem mount is
     * rarely level.
     */
    private val rotationSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    /** The fallback pair, for devices that report the raw sensors only. */
    private val accelSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val magneticSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)

    private var sink: EventChannel.EventSink? = null

    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private val accelerometer = FloatArray(3)
    private val magnetometer = FloatArray(3)

    private var hasAccelerometer = false
    private var hasMagnetometer = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val rotation = rotationSensor

        if (rotation != null) {
            sink = events
            sensorManager.registerListener(
                this,
                rotation,
                SensorManager.SENSOR_DELAY_UI,
            )
            return
        }

        val accel = accelSensor
        val magnetic = magneticSensor
        if (accel == null || magnetic == null) {
            // Not a failure: plenty of phones — and every Wi-Fi-only tablet —
            // have no magnetometer, and the app is fully usable without one.
            // Dart reads this as "no compass" and the heading falls back to
            // the GPS course.
            events.error("unavailable", "no compass on this device", null)
            return
        }

        sink = events
        hasAccelerometer = false
        hasMagnetometer = false
        sensorManager.registerListener(this, accel, SensorManager.SENSOR_DELAY_UI)
        sensorManager.registerListener(this, magnetic, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(
                    rotationMatrix,
                    event.values,
                )
                report(event, accuracyFromStatus(event.accuracy))
            }

            Sensor.TYPE_ACCELEROMETER -> {
                System.arraycopy(event.values, 0, accelerometer, 0, 3)
                hasAccelerometer = true
                report(event, accuracyFromStatus(event.accuracy))
            }

            Sensor.TYPE_MAGNETIC_FIELD -> {
                System.arraycopy(event.values, 0, magnetometer, 0, 3)
                hasMagnetometer = true
                report(event, accuracyFromStatus(event.accuracy))
            }
        }
    }

    /**
     * Turns whatever the last sensor event left in the buffers into a heading.
     *
     * Called for each of the two fallback sensors, which is what makes the pair
     * work: the first event cannot produce a rotation matrix (the other buffer
     * is still empty), and `getRotationMatrix` says so by returning false.
     */
    private fun report(event: SensorEvent, accuracyDegrees: Double?) {
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) {
            if (!hasAccelerometer || !hasMagnetometer) return
            if (!SensorManager.getRotationMatrix(
                    rotationMatrix,
                    null,
                    accelerometer,
                    magnetometer,
                )
            ) {
                return
            }
        }

        // No `remapCoordinateSystem` call, deliberately: the azimuth below is
        // the direction the *top of the phone* points, which is the direction
        // of travel for a phone mounted the way the bike faces. In landscape
        // that axis points sideways, so the heading would be 90° out — a
        // real-device question, listed in docs/gps.md rather than guessed at
        // here.
        //
        // Note also that this is a *magnetic* azimuth, and the GPS course it
        // is blended with is true north. The blend anchors the compass to a
        // recent GPS course, so a constant offset — declination, or the angle
        // the phone is mounted at — is absorbed by the anchor rather than
        // needing a declination model here.
        SensorManager.getOrientation(rotationMatrix, orientation)

        // `orientation[0]` is the azimuth in radians, positive anticlockwise
        // about the vertical; normalising it gives the compass bearing riders
        // expect — 0 north, 90 east.
        var degrees = Math.toDegrees(orientation[0].toDouble())
        if (degrees < 0) degrees += 360.0
        if (!degrees.isFinite()) return

        sink?.success(
            hashMapOf<String, Any?>("heading" to degrees, "accuracy" to accuracyDegrees)
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Nothing to do: the accuracy that matters is the one attached to each
        // reading, and it is mapped in `accuracyFromStatus` as the reading
        // goes out. A change here would only duplicate it.
    }

    /**
     * Maps Android's quality band onto the degrees the Dart side gates on.
     *
     * Android reports a category, not a figure, so these are honest
     * approximations rather than measurements: `HIGH` is good enough to use
     * on its own, `LOW` is the state a phone next to a steel frame or a
     * speaker magnet is in, and `UNRELIABLE` is reported as null so the
     * reading is dropped rather than believed.
     */
    private fun accuracyFromStatus(status: Int): Double? = when (status) {
        SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> 5.0
        SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> 15.0
        SensorManager.SENSOR_STATUS_ACCURACY_LOW -> 30.0
        else -> null
    }
}
