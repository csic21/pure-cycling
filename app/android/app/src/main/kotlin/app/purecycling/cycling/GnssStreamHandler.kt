package app.purecycling.cycling

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.GnssStatus
import android.location.Location
import android.location.LocationManager
import android.location.OnNmeaMessageListener
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.location.LocationListenerCompat
import androidx.core.location.LocationManagerCompat
import androidx.core.location.LocationRequestCompat
import io.flutter.plugin.common.EventChannel

/**
 * Satellite fixes from [LocationManager.GPS_PROVIDER], one per epoch.
 *
 * This is the path a bike navigation app uses on phones sold in China.
 * Google Play Services' fused provider is missing or throttled on a lot of
 * them, and Android 12's own `FUSED_PROVIDER` is allowed to sleep the chip.
 * Doppler speed (`Location.getSpeed`) only stays live when the request names
 * the GPS provider itself.
 *
 * Every fix is forwarded. A "keep the more accurate of the last two minutes"
 * filter is how a speed readout goes stale while the bike is moving.
 *
 * The geolocator foreground service is what keeps this process allowed to
 * receive fixes with the screen off. This handler does not start a second
 * one — a second ongoing notification is not a second satellite.
 */
class GnssStreamHandler(private val context: Context) :
    EventChannel.StreamHandler, LocationListenerCompat {

    private val locationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private var sink: EventChannel.EventSink? = null
    private var listening = false
    private var nmeaListener: OnNmeaMessageListener? = null

    @Volatile
    private var mslAltitude = Double.NaN

    @Volatile
    private var mslAtMs = 0L

    @Volatile
    private var satellitesUsed = 0

    @Volatile
    private var cn0AverageDbHz = Double.NaN

    private var gnssStatusCallback: GnssStatus.Callback? = null

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val interval = when (arguments) {
            is Int -> arguments.toLong()
            is Long -> arguments
            else -> 1000L
        }.coerceIn(500L, 10_000L)

        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            events.error("permission_denied", "fine location is not granted", null)
            return
        }
        if (!locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            events.error("gps_disabled", "GPS provider is off", null)
            return
        }

        sink = events
        startNmea()
        startGnssStatus()

        val request = LocationRequestCompat.Builder(interval)
            .setQuality(LocationRequestCompat.QUALITY_HIGH_ACCURACY)
            .setMinUpdateIntervalMillis(interval)
            .setMinUpdateDistanceMeters(0f)
            .build()

        listening = true
        LocationManagerCompat.requestLocationUpdates(
            locationManager,
            LocationManager.GPS_PROVIDER,
            request,
            this,
            Looper.getMainLooper(),
        )
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        if (listening) {
            locationManager.removeUpdates(this)
            listening = false
        }
        stopNmea()
        stopGnssStatus()
        sink = null
    }

    override fun onLocationChanged(location: Location) {
        val events = sink ?: return
        val altitude = mslAltitudeOf(location)
        val fix = hashMapOf<String, Any?>(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "timestamp" to location.time,
            "is_mocked" to isMocked(location),
        )
        if (altitude != null) fix["altitude"] = altitude
        if (location.hasAccuracy()) fix["accuracy"] = location.accuracy.toDouble()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasVerticalAccuracy()
        ) {
            fix["altitude_accuracy"] = location.verticalAccuracyMeters.toDouble()
        }
        if (location.hasSpeed()) fix["speed"] = location.speed.toDouble()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasSpeedAccuracy()
        ) {
            fix["speed_accuracy"] = location.speedAccuracyMetersPerSecond.toDouble()
        }
        if (location.hasBearing()) fix["heading"] = location.bearing.toDouble()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasBearingAccuracy()
        ) {
            fix["heading_accuracy"] = location.bearingAccuracyDegrees.toDouble()
        }
        // Satellite quality from the last GnssStatus callback. Zero used-in-fix
        // with a NaN CN0 means "not yet reported" and is omitted so Dart keeps
        // null rather than inventing an empty sky.
        val used = satellitesUsed
        if (used > 0) fix["satellites_used"] = used
        val cn0 = cn0AverageDbHz
        if (!cn0.isNaN()) fix["cn0_avg"] = cn0
        events.success(fix)
    }

    override fun onProviderDisabled(provider: String) {
        if (provider != LocationManager.GPS_PROVIDER) return
        sink?.error("gps_disabled", "GPS provider turned off", null)
        stop()
    }

    private fun mslAltitudeOf(location: Location): Double? {
        if (Build.VERSION.SDK_INT >= 34 && location.hasMslAltitude()) {
            return location.mslAltitudeMeters
        }
        val age = android.os.SystemClock.elapsedRealtime() - mslAtMs
        val nmea = mslAltitude
        if (!nmea.isNaN() && age in 0..5_000) return nmea
        return if (location.hasAltitude()) location.altitude else null
    }

    @SuppressLint("MissingPermission")
    private fun startNmea() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        if (nmeaListener != null) return
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val listener = OnNmeaMessageListener { message, _ ->
            val line = message.trim()
            if (!line.matches(Regex("^\\$..GGA.*$"))) return@OnNmeaMessageListener
            val tokens = line.split(',')
            if (tokens.size <= 9 || tokens[9].isEmpty()) return@OnNmeaMessageListener
            val parsed = tokens[9].toDoubleOrNull() ?: return@OnNmeaMessageListener
            mslAltitude = parsed
            mslAtMs = android.os.SystemClock.elapsedRealtime()
        }
        nmeaListener = listener
        locationManager.addNmeaListener(listener, null)
    }

    private fun stopNmea() {
        val listener = nmeaListener ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            locationManager.removeNmeaListener(listener)
        }
        nmeaListener = null
        mslAltitude = Double.NaN
        mslAtMs = 0L
    }

    /**
     * Listens for [GnssStatus] so each fix can carry used-in-fix count and
     * mean CN0. The numbers distinguish "accuracy looks fine but the sky is
     * thin" urban multipath from a genuinely solid lock — accuracy alone
     * cannot.
     *
     * API 24+. Older devices simply never populate the Dart fields.
     */
    @SuppressLint("MissingPermission")
    private fun startGnssStatus() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        if (gnssStatusCallback != null) return
        if (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val callback = object : GnssStatus.Callback() {
            override fun onSatelliteStatusChanged(status: GnssStatus) {
                var used = 0
                var cn0Sum = 0.0
                var cn0Count = 0
                for (i in 0 until status.satelliteCount) {
                    if (!status.usedInFix(i)) continue
                    used++
                    val cn0 = status.getCn0DbHz(i)
                    if (cn0 > 0f) {
                        cn0Sum += cn0
                        cn0Count++
                    }
                }
                satellitesUsed = used
                cn0AverageDbHz = if (cn0Count > 0) cn0Sum / cn0Count else Double.NaN
            }
        }
        gnssStatusCallback = callback
        locationManager.registerGnssStatusCallback(
            callback,
            Handler(Looper.getMainLooper()),
        )
    }

    private fun stopGnssStatus() {
        val callback = gnssStatusCallback ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            locationManager.unregisterGnssStatusCallback(callback)
        }
        gnssStatusCallback = null
        satellitesUsed = 0
        cn0AverageDbHz = Double.NaN
    }

    private fun isMocked(location: Location): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }
    }
}
