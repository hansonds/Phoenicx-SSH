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
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors

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

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val readers = HashMap<Int, InputStream>()
    private var nextHandle = 1

    /** Lists a picked folder: its name, every file (relative path, uri, size) and every sub-folder. */
    private fun listTree(tree: Uri): Map<String, Any> {
        val resolver = applicationContext.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        var name = "folder"
        resolver.query(DocumentsContract.buildDocumentUriUsingTree(tree, rootId),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0) ?: name
        }
        val files = ArrayList<Map<String, Any>>()
        val dirs = ArrayList<String>()
        val stack = ArrayDeque<Pair<String, String>>() // docId, relative path
        stack.add(rootId to "")
        while (stack.isNotEmpty()) {
            val (id, rel) = stack.removeLast()
            val kids = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            resolver.query(kids, arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val cid = c.getString(0)
                    val cname = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    val path = if (rel.isEmpty()) cname else "$rel/$cname"
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        dirs.add(path)
                        stack.add(cid to path)
                    } else {
                        files.add(mapOf(
                            "path" to path,
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, cid).toString(),
                            "size" to (if (c.isNull(3)) 0L else c.getLong(3))))
                    }
                }
            }
        }
        return mapOf("name" to name, "files" to files, "dirs" to dirs)
    }

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
                            Thread {
                                try {
                                    val shown = saveToDownloads(File(src), name, mime)
                                    main.post { result.success(shown) }
                                } catch (e: Exception) {
                                    main.post { result.error("SAVE", e.message, null) }
                                }
                            }.start()
                        }
                        "listTree" -> {
                            // Everything inside a folder the user picked (SAF tree URI).
                            val tree = Uri.parse(call.argument<String>("uri")!!)
                            io.execute {
                                try {
                                    val r = listTree(tree)
                                    main.post { result.success(r) }
                                } catch (e: Exception) {
                                    main.post { result.error("LIST", e.message, null) }
                                }
                            }
                        }
                        "openRead" -> {
                            val uri = Uri.parse(call.argument<String>("uri")!!)
                            io.execute {
                                try {
                                    val ins = applicationContext.contentResolver.openInputStream(uri)
                                        ?: throw Exception("Can't open the file")
                                    val h = nextHandle++
                                    readers[h] = ins
                                    main.post { result.success(h) }
                                } catch (e: Exception) {
                                    main.post { result.error("OPEN", e.message, null) }
                                }
                            }
                        }
                        "read" -> {
                            val h = call.argument<Int>("h")!!
                            val n = call.argument<Int>("n") ?: 262144
                            io.execute {
                                try {
                                    val ins = readers[h] ?: throw Exception("File is closed")
                                    val buf = ByteArray(n)
                                    var got = 0
                                    while (got < n) {
                                        val r = ins.read(buf, got, n - got)
                                        if (r < 0) break
                                        got += r
                                    }
                                    val out = if (got == 0) null else if (got == n) buf else buf.copyOf(got)
                                    main.post { result.success(out) }
                                } catch (e: Exception) {
                                    main.post { result.error("READ", e.message, null) }
                                }
                            }
                        }
                        "closeRead" -> {
                            val h = call.argument<Int>("h")!!
                            io.execute {
                                try { readers.remove(h)?.close() } catch (_: Exception) {}
                                main.post { result.success(null) }
                            }
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
