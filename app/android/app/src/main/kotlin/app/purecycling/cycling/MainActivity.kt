package app.purecycling.cycling

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private var barometer: BarometerStreamHandler? = null
    private var compass: CompassStreamHandler? = null
    private var motion: MotionStreamHandler? = null
    private var rideFullscreen = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, RIDE_FULLSCREEN_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "setImmersive") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            rideFullscreen = call.arguments == true
            applyRideFullscreen()
            result.success(null)
        }

        MethodChannel(messenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "install") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val apk = acceptedUpdate(call.argument<String>("path"))
            if (apk == null) {
                result.error("invalid_apk", "安装包文件无效，请重新下载", null)
                return@setMethodCallHandler
            }
            @Suppress("DEPRECATION")
            val archive = packageManager.getPackageArchiveInfo(apk.path, 0)
            @Suppress("DEPRECATION")
            val installed = packageManager.getPackageInfo(packageName, 0)
            val archiveCode = if (Build.VERSION.SDK_INT >= 28) {
                archive?.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                archive?.versionCode?.toLong()
            }
            val installedCode = if (Build.VERSION.SDK_INT >= 28) {
                installed.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                installed.versionCode.toLong()
            }
            if (archive?.packageName != packageName ||
                archiveCode == null || archiveCode <= installedCode) {
                result.error("invalid_apk", "安装包与当前应用不匹配或版本未更新", null)
                return@setMethodCallHandler
            }
            // The update feed is cached, so the release it describes can be
            // replaced — or rolled back — while a rider is downloading. If the
            // file does not carry the version they were promised, refuse it.
            // The alternative is quietly reinstalling the build that is
            // already on the phone and calling that an update.
            val advertised = call.argument<String>("version")
            if (advertised != null && archive?.versionName != advertised) {
                result.error(
                    "invalid_apk", "下载到的安装包不是提示的新版本，请重新检查更新", null
                )
                return@setMethodCallHandler
            }
            try {
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.updates", apk
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    // NEW_TASK so a package-installer activity still showing the
                    // previous URI is not reused. The URI itself also changes
                    // per download; either half alone still served the old APK
                    // on several OEM installers.
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK,
                    )
                }
                startActivity(intent)
                result.success(null)
            } catch (_: ActivityNotFoundException) {
                result.error("installer_unavailable", "无法打开系统安装界面", null)
            } catch (_: SecurityException) {
                result.error("install_denied", "请允许此应用安装更新后重试", null)
            }
        }

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

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && rideFullscreen) applyRideFullscreen()
    }

    /// A download this process just wrote, and nothing else.
    ///
    /// The name has to be `update-<digits>.apk`. A fixed name makes the
    /// content URI stable, and the system installer caches the APK it parsed
    /// for that URI — so the dialog keeps offering the build the rider
    /// already installed.
    private fun acceptedUpdate(path: String?): File? {
        val apk = path?.let { runCatching { File(it).canonicalFile }.getOrNull() }
            ?: return null
        val updates = File(cacheDir, "updates").canonicalFile
        if (apk.parentFile != updates) return null
        if (!updateName.matches(apk.name)) return null
        if (!apk.isFile || apk.length() == 0L) return null
        return apk
    }

    private fun applyRideFullscreen() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let { controller ->
                if (rideFullscreen) {
                    controller.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(WindowInsets.Type.systemBars())
                } else {
                    controller.show(WindowInsets.Type.systemBars())
                }
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = if (rideFullscreen) {
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            } else {
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            }
        }
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
        private val updateName = Regex("update-[0-9]+\\.apk")

        const val UPDATE_CHANNEL = "app.purecycling/update"
        const val RIDE_FULLSCREEN_CHANNEL = "app.purecycling/ride_fullscreen"
        /** Must match `PlatformBarometerSource.channelName` on the Dart side. */
        const val BAROMETER_CHANNEL = "app.purecycling/barometer"

        /** Must match `PlatformCompassSource.channelName` on the Dart side. */
        const val COMPASS_CHANNEL = "app.purecycling/compass"

        /** Must match `PlatformMotionSource.channelName` on the Dart side. */
        const val MOTION_CHANNEL = "app.purecycling/motion"
    }
}
