package com.hanson.phoenicx_ssh

import android.content.Context
import android.content.Intent
import android.content.ContentValues
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

    private fun saveToDownloads(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Phoenicx SSH")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = applicationContext.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Android refused to create the file")
            try {
                resolver.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out, 1 shl 16) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return "Download/Phoenicx SSH/$name"
        }
        // Android 9 and older: the app's own Downloads folder (no permission needed).
        val dir = File(applicationContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "")
        dir.mkdirs()
        var dest = File(dir, name)
        var n = 1
        while (dest.exists()) {
            val dot = name.lastIndexOf('.')
            dest = if (dot > 0) File(dir, name.substring(0, dot) + " ($n)" + name.substring(dot))
            else File(dir, "$name ($n)")
            n++
        }
        src.copyTo(dest)
        return dest.absolutePath
    }

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
                            // Opens Android's battery-optimisation list (no special
                            // permission needed - Play-policy friendly). Falls back to
                            // this app's settings page.
                            try {
                                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            } catch (e: Exception) {
                                val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                i.data = Uri.parse("package:$packageName")
                                startActivity(i)
                            }
                            result.success(true)
                        }
                        "saveToDownloads" -> {
                            // Copies a finished download (a temp file) into the
                            // public Download/Phoenicx SSH folder. Uses MediaStore,
                            // so no storage permission is needed.
                            val src = call.argument<String>("path")!!
                            val name = call.argument<String>("name")!!
                            val mime = call.argument<String>("mime") ?: "application/octet-stream"
                            val main = Handler(Looper.getMainLooper())
                            Thread {
                                try {
                                    val shown = saveToDownloads(File(src), name, mime)
                                    main.post { result.success(shown) }
                                } catch (e: Exception) {
                                    main.post { result.error("SAVE", e.message, null) }
                                }
                            }.start()
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
