package app.compii.compii

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Notifications as they arrive, kept on the phone only. Compii's rules read
 * this live stream and decide whether to send anything to the PC; the recent
 * list is there when the user asks what they missed.
 */
class CompiiNotificationListener : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        // What is already on the shade, so "what did I miss?" isn't empty right after turning this on.
        try {
            activeNotifications
                ?.filter { usable(it) }
                ?.sortedBy { it.postTime }
                ?.takeLast(MAX_RECENT)
                ?.forEach { remember(toEvent(it)) }
        } catch (_: Exception) {
            // some OEMs refuse this until the next post; the live stream still works
        }
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || !usable(sbn)) return
        val event = toEvent(sbn)
        if (event["title"].toString().isEmpty() && event["text"].toString().isEmpty()) return
        remember(event)
        onPost?.invoke(event)
    }

    private fun usable(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName == packageName) return false  // Compii's own alerts
        val n = sbn.notification ?: return false
        if (sbn.isOngoing) return false
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        return true
    }

    private fun toEvent(sbn: StatusBarNotification): Map<String, Any> {
        val extras = sbn.notification?.extras
        val title = firstText(extras, Notification.EXTRA_TITLE)
        val text = firstText(
            extras,
            Notification.EXTRA_TEXT,
            Notification.EXTRA_BIG_TEXT,
            Notification.EXTRA_SUMMARY_TEXT,
        )
        return mapOf(
            "type" to "notification",
            "key" to sbn.key,
            "app" to appLabel(sbn.packageName),
            "package" to sbn.packageName,
            "title" to title,
            "text" to text,
            "at" to sbn.postTime,
        )
    }

    private fun firstText(extras: android.os.Bundle?, vararg keys: String): String {
        if (extras == null) return ""
        for (key in keys) {
            val value = extras.getCharSequence(key)?.toString()?.replace(SPACES, " ")?.trim().orEmpty()
            if (value.isNotEmpty()) return value.take(300)
        }
        return ""
    }

    private fun appLabel(pkg: String): String = try {
        val pm = packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) {
        pkg
    }

    companion object {
        private const val MAX_RECENT = 40
        private val SPACES = Regex("\\s+")
        private val notes = ArrayList<Map<String, Any>>()

        /** MainActivity points this at the Flutter event stream while the app runs. */
        @Volatile
        var onPost: ((Map<String, Any>) -> Unit)? = null

        @Volatile
        var instance: CompiiNotificationListener? = null
            private set

        private fun remember(event: Map<String, Any>) {
            synchronized(notes) {
                notes.removeAll { it["key"] == event["key"] }
                notes.add(0, event)
                while (notes.size > MAX_RECENT) notes.removeAt(notes.lastIndex)
            }
        }

        fun recent(): List<Map<String, Any>> = synchronized(notes) { notes.toList() }

        /** Turned on in Android settings, whether or not the service is bound yet. */
        fun enabled(context: Context): Boolean {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            if (manager != null && Build.VERSION.SDK_INT >= 27) {
                try {
                    return manager.isNotificationListenerAccessGranted(
                        ComponentName(context, CompiiNotificationListener::class.java),
                    )
                } catch (_: Exception) {
                    // fall through to the setting
                }
            }
            val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            return flat?.contains(context.packageName) == true
        }
    }
}
