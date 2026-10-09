package app.purecycling.cycling

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Surface
import android.view.WindowManager
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
 * The heading of the top of the current display. Remap the sensor matrix
 * before reading azimuth, so landscape works even on a tilted handlebar mount.
 * Dart receives the display frame too, and discards an old mounting calibration
 * when it changes. Only GPS determines the actual direction of travel.
 *
 * It does **not** smooth, filter, or decide whether to be believed. That is
 * the interesting part, it has a right answer that can be tested without a
 * device, and it lives in Dart (`core/location/gps_filter.dart`).
 *
 * Neither `TYPE_ROTATION_VECTOR` nor the accelerometer/magnetometer fallback
 * needs any permission.
 */
class CompassStreamHandler(private val context: Context) :
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
    private val displayMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private val accelerometer = FloatArray(3)
    private val magnetometer = FloatArray(3)

    private var hasAccelerometer = false
    private var hasMagnetometer = false
    private var magneticAccuracy = SensorManager.SENSOR_STATUS_UNRELIABLE

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
        magneticAccuracy = SensorManager.SENSOR_STATUS_UNRELIABLE
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
                report(event, accuracyFromStatus(magneticAccuracy))
            }

            Sensor.TYPE_MAGNETIC_FIELD -> {
                System.arraycopy(event.values, 0, magnetometer, 0, 3)
                hasMagnetometer = true
                magneticAccuracy = event.accuracy
                report(event, accuracyFromStatus(magneticAccuracy))
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

        // Sensor axes never rotate with the display. Adding 90 degrees to
        // an already-derived azimuth is wrong when the mount is tilted: remap
        // the 3D frame first, then calculate its azimuth.
        val rotation = displayRotation()
        val (axisX, axisY) = when (rotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
        }
        if (!SensorManager.remapCoordinateSystem(rotationMatrix, axisX, axisY, displayMatrix)) return
        SensorManager.getOrientation(displayMatrix, orientation)

        // Magnetic north here; the Dart GPS-course anchor absorbs declination.
        var degrees = Math.toDegrees(orientation[0].toDouble())
        if (degrees < 0) degrees += 360.0
        if (!degrees.isFinite()) return

        sink?.success(
            hashMapOf<String, Any?>(
                "heading" to degrees,
                "accuracy" to accuracyDegrees,
                "orientationQuarterTurns" to rotation,
            )
        )
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.display?.rotation ?: Surface.ROTATION_0
    } else {
        (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.rotation
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        if (sensor?.type == Sensor.TYPE_MAGNETIC_FIELD) magneticAccuracy = accuracy
    }

    /**
     * Maps Android's quality band onto the degrees the Dart side gates on.
     *
     * Android reports a category, not a figure, so these are honest
     * approximations rather than measurements: `HIGH` is good enough to use
     * on its own, `LOW` is the state a phone next to a steel frame or a
     * speaker magnet is in, and `UNRELIABLE` is reported as 180 degrees so the
     * reading is dropped rather than believed.
     */
    private fun accuracyFromStatus(status: Int): Double = when (status) {
        SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> 5.0
        SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> 15.0
        SensorManager.SENSOR_STATUS_ACCURACY_LOW -> 30.0
        else -> 180.0
    }
}
