package ru.svoi.svoi

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Разрешение видеть номер входящего звонка — для автоподстановки кода из звонка-сброса.
 * Своё маленькое, чтобы не тянуть большой плагин разрешений ради одного окна.
 */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    private val callPermissions = arrayOf(
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ru.svoi/call_permission")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "has" -> result.success(granted())
                    "request" -> {
                        if (granted()) {
                            result.success(true)
                        } else {
                            pending?.success(false)
                            pending = result
                            requestPermissions(callPermissions, REQUEST_CODE)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun granted() = callPermissions.all {
        checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE) {
            pending?.success(granted())
            pending = null
        }
    }

    private companion object {
        const val REQUEST_CODE = 4821
    }
}
