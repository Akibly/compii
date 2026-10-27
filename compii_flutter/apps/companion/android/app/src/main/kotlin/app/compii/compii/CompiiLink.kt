package app.compii.compii

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import org.json.JSONArray
import org.json.JSONObject
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

/**
 * Compii's link to the paired PC while the app is closed: one quiet long poll to
 * Core's /phone/signals, turned into notifications. Approvals carry Approve and
 * Deny buttons that answer the PC directly, without opening the app.
 *
 * It trusts exactly one certificate — the PC's, by the SHA-256 fingerprint from
 * the pairing QR code — and sends the phone's own device key, the same as the app.
 * No third party carries anything: no Google push, no relay.
 */
object CompiiLink {
    private const val PREFS = "compii_link"
    const val WORK_CHANNEL = "compii_work"
    const val LINK_CHANNEL = "compii_link"
    const val ONGOING_ID = 7400

    /** The app is on screen: it shows its own banners, so the link stays quiet. */
    @Volatile var appVisible = false

    data class Config(val hosts: List<String>, val port: Int, val fingerprint: String, val token: String, val pc: String)

    fun save(context: Context, config: Config) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("hosts", JSONArray(config.hosts).toString())
            .putInt("port", config.port)
            .putString("fingerprint", config.fingerprint)
            .putString("token", config.token)
            .putString("pc", config.pc)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun load(context: Context): Config? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val token = p.getString("token", null) ?: return null
        val raw = JSONArray(p.getString("hosts", "[]"))
        val hosts = (0 until raw.length()).map { raw.getString(it) }.filter { it.isNotBlank() }
        if (hosts.isEmpty()) return null
        return Config(hosts, p.getInt("port", 0), p.getString("fingerprint", "") ?: "", token, p.getString("pc", "your PC") ?: "your PC")
    }

    fun since(context: Context): Double =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getFloat("since", 0f).toDouble()

    fun setSince(context: Context, value: Double) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putFloat("since", value.toFloat()).apply()
    }

    fun start(context: Context) {
        val intent = Intent(context, CompiiLinkService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }

    fun stop(context: Context) {
        context.stopService(Intent(context, CompiiLinkService::class.java))
    }

    /** One request to the paired PC: pinned certificate, device key, short timeouts. */
    fun request(config: Config, host: String, path: String, body: String? = null, readTimeoutMs: Int = 15000): String {
        val want = config.fingerprint.lowercase().replace(":", "")
        val trust = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val got = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                    .joinToString("") { "%02x".format(it) }
                if (got != want) throw CertificateException("This isn't the PC you paired with.")
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        val c = URL("https://$host:${config.port}$path").openConnection() as HttpsURLConnection
        c.sslSocketFactory = tls.socketFactory
        // The PC's identity is the pinned certificate above, not a hostname.
        c.hostnameVerifier = HostnameVerifier { _, _ -> true }
        c.connectTimeout = 8000
        c.readTimeout = readTimeoutMs
        c.setRequestProperty("X-Compii-Device", config.token)
        c.setRequestProperty("User-Agent", "Compii phone")
        if (body != null) {
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write(body.toByteArray()) }
        }
        try {
            val code = c.responseCode
            val text = (if (code < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (code >= 400) throw RuntimeException("$code: ${text.take(200)}")
            return text
        } finally {
            c.disconnect()
        }
    }

    fun channels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val m = context.getSystemService(NotificationManager::class.java)
        m.createNotificationChannel(NotificationChannel(WORK_CHANNEL, "Compii work", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Answers, approvals and questions from Compii on your PC."
            enableVibration(true)
        })
        m.createNotificationChannel(NotificationChannel(LINK_CHANNEL, "Connected to your PC", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Keeps Compii connected so approvals reach you with the app closed. You can hide this."
            setShowBadge(false)
        })
    }

    fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel)
        else @Suppress("DEPRECATION") Notification.Builder(context)

    fun openIntent(context: Context, destination: String, code: Int): PendingIntent {
        val tap = Intent(context, MainActivity::class.java).apply {
            putExtra("compii_dest", destination)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        return PendingIntent.getActivity(context, code, tap, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun approvalTag(id: String) = "link_approval:$id"
}

class CompiiLinkService : Service() {
    @Volatile private var running = false
    private val posted = mutableSetOf<String>() // approval ids with a notification up

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        CompiiLink.channels(this)
        val config = CompiiLink.load(this)
        val ongoing = ongoing(config?.pc ?: "your PC", "Approvals and answers reach you here.")
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(CompiiLink.ONGOING_ID, ongoing, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(CompiiLink.ONGOING_ID, ongoing)
        }
        if (config == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!running) {
            running = true
            thread(name = "compii-link", isDaemon = true) { loop() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun ongoing(pc: String, text: String): Notification =
        CompiiLink.builder(this, CompiiLink.LINK_CHANNEL)
            .setSmallIcon(R.drawable.ic_compii)
            .setContentTitle("Connected to $pc")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(CompiiLink.openIntent(this, "talk", 7401))
            .build()

    private fun manager() = getSystemService(NotificationManager::class.java)

    private fun loop() {
        var backoff = 5L
        var pending = listOf<String>()
        var host = 0
        if (CompiiLink.since(this) == 0.0) {
            // First connection: start from now, not from the PC's whole history.
            CompiiLink.setSince(this, System.currentTimeMillis() / 1000.0 - 60)
        }
        while (running) {
            val config = CompiiLink.load(this) ?: break
            val target = config.hosts[host % config.hosts.size]
            try {
                val q = "/phone/signals?since=${CompiiLink.since(this)}&wait=50&pending=" +
                    URLEncoder.encode(pending.joinToString(","), "UTF-8")
                val out = JSONObject(CompiiLink.request(config, target, q, readTimeoutMs = 65000))
                backoff = 5L
                manager().notify(CompiiLink.ONGOING_ID, ongoing(config.pc, "Approvals and answers reach you here."))
                handle(out)
                val p = out.optJSONArray("pending") ?: JSONArray()
                pending = (0 until p.length()).map { p.getString(it) }
                clearAnswered(pending)
            } catch (e: Exception) {
                host += 1 // try the PC's next address (Wi-Fi, then Tailscale)
                manager().notify(CompiiLink.ONGOING_ID, ongoing(config.pc, "Can't reach ${config.pc} right now — trying again."))
                try { Thread.sleep(backoff * 1000) } catch (_: InterruptedException) { }
                backoff = minOf(backoff * 2, 60L)
            }
        }
    }

    private fun handle(out: JSONObject) {
        val list = out.optJSONArray("signals") ?: JSONArray()
        for (i in 0 until list.length()) {
            val s = list.getJSONObject(i)
            if (!CompiiLink.appVisible) post(s)
        }
        CompiiLink.setSince(this, out.optDouble("now", CompiiLink.since(this)))
    }

    private fun post(s: JSONObject) {
        val kind = s.optString("kind")
        val id = s.optString("id")
        val task = s.optString("task_id")
        val title = s.optString("title", "Compii")
        val body = s.optString("body")
        val dest = if (task.isNotBlank()) "task:$task" else "chats"
        val tag = if (kind == "needs_you") CompiiLink.approvalTag(id) else "link:$kind:$id"
        val (heading, text) = when (kind) {
            "needs_you" -> "Compii needs your OK" to body
            "question" -> "Compii is asking you something" to body
            "done" -> "Done: $title" to body
            "failed" -> "Didn't finish: $title" to body
            "update" -> title to body
            else -> title to body
        }
        val b = CompiiLink.builder(this, CompiiLink.WORK_CHANNEL)
            .setSmallIcon(R.drawable.ic_compii)
            .setContentTitle(heading)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(if (kind == "needs_you") "$text\n\nIn: $title" else text))
            .setAutoCancel(true)
            .setContentIntent(CompiiLink.openIntent(this, dest, tag.hashCode()))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup("compii")
            .setPublicVersion(
                CompiiLink.builder(this, CompiiLink.WORK_CHANNEL).setSmallIcon(R.drawable.ic_compii)
                    .setContentTitle("Compii").setContentText("There’s something new from your PC.").build(),
            )
        if (kind == "needs_you") {
            b.setAutoCancel(false)
            b.addAction(action("Deny", id, false, tag, title))
            b.addAction(action("Approve", id, true, tag, title))
            posted.add(id)
        }
        manager().notify(tag.hashCode(), b.build())
    }

    private fun action(label: String, approvalId: String, approve: Boolean, tag: String, title: String): Notification.Action {
        val i = Intent(this, ApprovalReceiver::class.java).apply {
            putExtra("approval_id", approvalId)
            putExtra("approve", approve)
            putExtra("tag", tag)
            putExtra("title", title)
        }
        val pi = PendingIntent.getBroadcast(
            this, (tag + approve).hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(null, label, pi).build()
    }

    /** An approval answered anywhere else (on the PC, in the app) leaves the phone too. */
    private fun clearAnswered(pending: List<String>) {
        val gone = posted.filter { it !in pending }
        for (id in gone) {
            manager().cancel(CompiiLink.approvalTag(id).hashCode())
            posted.remove(id)
        }
    }
}

/** Approve or Deny from the notification: answered on the PC, then said on the phone. */
class ApprovalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("approval_id") ?: return
        val approve = intent.getBooleanExtra("approve", false)
        val tag = intent.getStringExtra("tag") ?: CompiiLink.approvalTag(id)
        val title = intent.getStringExtra("title") ?: "Compii"
        val done = goAsync()
        thread {
            val m = context.getSystemService(NotificationManager::class.java)
            val text = try {
                val config = CompiiLink.load(context) ?: throw RuntimeException("not paired")
                var last: Exception? = null
                var ok = false
                for (host in config.hosts) {
                    try {
                        CompiiLink.request(config, host, "/approvals/${URLEncoder.encode(id, "UTF-8")}", "{\"approved\": $approve}")
                        ok = true
                        break
                    } catch (e: Exception) {
                        last = e
                    }
                }
                if (!ok) throw last ?: RuntimeException("no address")
                if (approve) "Approved — Compii is carrying on." else "Denied — Compii won't do it."
            } catch (e: Exception) {
                if ((e.message ?: "").startsWith("404")) "Already answered." else "Couldn't reach your PC. Tap to open Compii."
            }
            m.notify(
                tag.hashCode(),
                CompiiLink.builder(context, CompiiLink.WORK_CHANNEL)
                    .setSmallIcon(R.drawable.ic_compii)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setAutoCancel(true)
                    .setContentIntent(CompiiLink.openIntent(context, "chats", tag.hashCode()))
                    .build(),
            )
            done.finish()
        }
    }
}

/** After a restart, reconnect if the phone is paired and the link was on. */
class LinkBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && CompiiLink.load(context) != null) {
            try {
                CompiiLink.start(context)
            } catch (_: Exception) {
                // Not allowed right now (battery rules): the app restarts it when opened.
            }
        }
    }
}
