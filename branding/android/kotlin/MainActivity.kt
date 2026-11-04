package com.hanson.phoenicx_ssh

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val ENGINE_ID = "phoenicx_main"
    }

    // The Flutter engine (and with it every open SSH session) lives in the
    // process, not in this Activity. Closing or swiping away the screen does
    // not end the sessions while the keep-alive service is running.
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "phoenicx_ssh/keepalive")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            val i = Intent(applicationContext, KeepAliveService::class.java)
                            i.putExtra("text", call.argument<String>("text") ?: "SSH sessions connected")
                            i.putExtra("wakeLock", call.argument<Boolean>("wakeLock") ?: true)
                            if (Build.VERSION.SDK_INT >= 26) {
                                applicationContext.startForegroundService(i)
                            } else {
                                applicationContext.startService(i)
                            }
                            result.success(true)
                        }
                        "stop" -> {
                            applicationContext.stopService(Intent(applicationContext, KeepAliveService::class.java))
                            result.success(true)
                        }
                        "notifPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
                            ) {
                                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7)
                            }
                            result.success(true)
                        }
                        "battery" -> {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                i.data = Uri.parse("package:$packageName")
                                startActivity(i)
                            } else {
                                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            }
                            result.success(true)
                        }
                        "background" -> {
                            moveTaskToBack(true)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERR", e.message, null)
                }
            }
    }
}
