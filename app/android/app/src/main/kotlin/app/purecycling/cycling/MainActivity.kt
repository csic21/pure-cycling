package app.purecycling.cycling

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "install") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val expected = File(cacheDir, "updates/update.apk").canonicalFile
            val apk = path?.let { File(it).canonicalFile }
            if (apk == null || apk != expected || !apk.isFile || apk.length() == 0L) {
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
            try {
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.updates", apk
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
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
        const val UPDATE_CHANNEL = "app.purecycling/update"
        /** Must match `PlatformBarometerSource.channelName` on the Dart side. */
        const val BAROMETER_CHANNEL = "app.purecycling/barometer"

        /** Must match `PlatformCompassSource.channelName` on the Dart side. */
        const val COMPASS_CHANNEL = "app.purecycling/compass"

        /** Must match `PlatformMotionSource.channelName` on the Dart side. */
        const val MOTION_CHANNEL = "app.purecycling/motion"
    }
}
