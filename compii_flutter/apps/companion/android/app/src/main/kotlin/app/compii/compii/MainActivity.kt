package app.compii.compii

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Compii on the phone: the phone's own text-to-speech voice, notifications and
 * the home-screen widget, and text or links shared in from other apps.
 */
class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var channel: MethodChannel? = null

    private var eventSink: EventChannel.EventSink? = null
    private var automationSink: EventChannel.EventSink? = null
    private var pendingShare: Map<String, String>? = null
    private var pendingDestination: String? = null
    private var permissionResult: MethodChannel.Result? = null

    override fun onResume() {
        super.onResume()
        CompiiLink.appVisible = true
    }

    override fun onPause() {
        CompiiLink.appVisible = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setUpSpeech(flutterEngine)
        setUpPhone(flutterEngine)
        setUpAutomation(flutterEngine)
        createAlertChannel()
        handleIntent(intent)
    }

    private fun setUpSpeech(flutterEngine: FlutterEngine) {
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/speech")
        channel = ch
        tts = TextToSpeech(this) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) tts?.language = Locale.getDefault()
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) = post("start")
            override fun onDone(id: String?) = post("done")
            override fun onStop(id: String?, interrupted: Boolean) = post("done")
            @Deprecated("Deprecated in Java")
            override fun onError(id: String?) = post("done")
        })
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    if (!ready) {
                        result.success(false)
                    } else {
                        tts?.speak(call.argument<String>("text") ?: "", TextToSpeech.QUEUE_FLUSH, null, "compii")
                        result.success(true)
                    }
                }
                "stop" -> {
                    tts?.stop()
                    result.success(true)
                }
                "chime" -> {
                    val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 70)
                    tone.startTone(ToneGenerator.TONE_PROP_ACK, 180)
                    Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 300)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setUpPhone(flutterEngine: FlutterEngine) {
        val phone = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/phone")
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/phone_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    flushPending()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        phone.setMethodCallHandler { call, result ->
            when (call.method) {
                "notificationsAllowed" -> result.success(notificationsAllowed())
                "requestNotifications" -> requestNotifications(result)
                "notify" -> {
                    showAlert(
                        call.argument<String>("tag"),
                        call.argument<String>("title"),
                        call.argument<String>("body"),
                        call.argument<String>("destination"),
                    )
                    result.success(true)
                }
                "cancel" -> {
                    call.argument<String>("tag")?.let { manager().cancel(it.hashCode()) }
                    result.success(true)
                }
                "cancelAll" -> {
                    manager().cancelAll()
                    result.success(true)
                }
                "widget" -> {
                    saveWidget(
                        call.argument<String>("headline") ?: "Compii",
                        call.argument<String>("detail") ?: "",
                        call.argument<String>("meta") ?: "",
                    )
                    result.success(true)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(true)
                }
                "startLink" -> {
                    val hosts = call.argument<List<String>>("hosts") ?: emptyList()
                    CompiiLink.save(this, CompiiLink.Config(
                        hosts,
                        call.argument<Int>("port") ?: 0,
                        call.argument<String>("fingerprint") ?: "",
                        call.argument<String>("token") ?: "",
                        call.argument<String>("pc") ?: "your PC",
                    ))
                    try {
                        CompiiLink.start(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopLink" -> {
                    CompiiLink.stop(this)
                    CompiiLink.clear(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun post(event: String) {
        runOnUiThread { channel?.invokeMethod(event, null) }
    }

    // ---- this phone's screen and notifications ---------------------------------

    private fun setUpAutomation(flutterEngine: FlutterEngine) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/automation_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    automationSink = events
                }

                override fun onCancel(arguments: Any?) {
                    automationSink = null
                }
            })
        CompiiNotificationListener.onPost = { event ->
            runOnUiThread { automationSink?.success(event) }
        }
        val automation = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compii/automation")
        automation.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "screen" to CompiiAccessibilityService.enabled(this),
                        "screenReady" to (CompiiAccessibilityService.instance != null),
                        "notifications" to CompiiNotificationListener.enabled(this),
                        "notificationsReady" to (CompiiNotificationListener.instance != null),
                    ),
                )
                "screen" -> result.success(CompiiAccessibilityService.instance?.snapshot())
                "tap" -> result.success(
                    CompiiAccessibilityService.instance?.tapText(call.argument<String>("text") ?: "") ?: false,
                )
                "type" -> result.success(
                    CompiiAccessibilityService.instance?.type(call.argument<String>("text") ?: "") ?: false,
                )
                "scroll" -> result.success(
                    CompiiAccessibilityService.instance?.scroll(call.argument<String>("direction") ?: "down") ?: false,
                )
                "global" -> result.success(
                    CompiiAccessibilityService.instance?.global(call.argument<String>("action") ?: "") ?: false,
                )
                "openApp" -> result.success(
                    CompiiAccessibilityService.instance?.openApp(call.argument<String>("query") ?: ""),
                )
                "notifications" -> result.success(CompiiNotificationListener.recent())
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                "openListenerSettings" -> {
                    openListenerSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openListenerSettings() {
        try {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        } catch (_: Exception) {
            openNotificationSettings()
        }
    }

    // ---- alerts ----------------------------------------------------------------

    private fun manager(): NotificationManager = getSystemService(NotificationManager::class.java)

    private fun createAlertChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Compii work", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Answers, approvals and questions from Compii on your PC."
                enableVibration(true)
            }
            manager().createNotificationChannel(ch)
        }
    }

    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 24 && !manager().areNotificationsEnabled()) return false
        return if (Build.VERSION.SDK_INT >= 33) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 || notificationsAllowed()) {
            result.success(notificationsAllowed())
            return
        }
        if (permissionResult != null) {
            result.success(false)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            permissionResult?.success(notificationsAllowed())
            permissionResult = null
        }
    }

    private fun showAlert(tag: String?, title: String?, body: String?, destination: String?) {
        if (tag.isNullOrBlank() || !notificationsAllowed()) return
        val tap = Intent(this, MainActivity::class.java).apply {
            putExtra("compii_dest", destination ?: "chats")
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val id = tag.hashCode()
        val open = PendingIntent.getActivity(
            this, id, tap, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = builder()
            .setSmallIcon(R.drawable.ic_compii)
            .setContentTitle(title ?: "Compii")
            .setContentText(body ?: "")
            .setStyle(Notification.BigTextStyle().bigText(body ?: ""))
            .setAutoCancel(true)
            .setContentIntent(open)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup("compii")
        // The lock screen gets the fact, not the content: what Compii found on
        // your PC stays private until the phone is unlocked.
        builder.setPublicVersion(
            builder()
                .setSmallIcon(R.drawable.ic_compii)
                .setContentTitle("Compii")
                .setContentText("There’s something new from your PC.")
                .build(),
        )
        manager().notify(id, builder.build())
    }

    private fun builder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL).setPriority(Notification.PRIORITY_HIGH)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }

    private fun openNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    // ---- widget -----------------------------------------------------------------

    private fun saveWidget(headline: String, detail: String, meta: String) {
        getSharedPreferences(WIDGET_PREFS, MODE_PRIVATE).edit()
            .putString("headline", headline)
            .putString("detail", detail)
            .putString("meta", meta)
            .apply()
        CompiiWidgetProvider.refresh(this)
    }

    // ---- shares and taps --------------------------------------------------------

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        intent.getStringExtra("compii_dest")?.takeIf { it.isNotBlank() }?.let {
            deliver(mapOf("type" to "open", "destination" to it))
            intent.removeExtra("compii_dest")
        }
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
                if (text.isNotEmpty()) {
                    val event = mutableMapOf("type" to "share", "text" to text)
                    intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }?.let { event["subject"] = it }
                    deliver(event)
                }
            }
            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.trim().orEmpty()
                if (text.isNotEmpty()) deliver(mapOf("type" to "share", "text" to text))
            }
        }
    }

    private fun deliver(event: Map<String, String>) {
        val sink = eventSink
        if (sink != null) {
            runOnUiThread { sink.success(event) }
            return
        }
        if (event["type"] == "share") {
            pendingShare = event
        } else {
            pendingDestination = event["destination"]
        }
    }

    private fun flushPending() {
        val sink = eventSink ?: return
        pendingDestination?.let {
            sink.success(mapOf("type" to "open", "destination" to it))
            pendingDestination = null
        }
        pendingShare?.let {
            sink.success(it)
            pendingShare = null
        }
    }

    override fun onDestroy() {
        tts?.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "compii_work"
        private const val WIDGET_PREFS = "compii_widget"
        private const val PERMISSION_REQUEST = 7301
    }
}
