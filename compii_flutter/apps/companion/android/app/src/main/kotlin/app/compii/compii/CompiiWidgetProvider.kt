package app.compii.compii

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * A small live card on the home screen: what Compii is doing on the PC, and
 * one tap to talk, to show Compii a photo, or to see the conversations. The phone writes the words; the
 * provider only draws them.
 */
class CompiiWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences("compii_widget", Context.MODE_PRIVATE)
        val headline = prefs.getString("headline", "Compii") ?: "Compii"
        val detail = prefs.getString("detail", "Pair your phone and ask anything.") ?: ""
        val meta = prefs.getString("meta", "Ready") ?: ""
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_compii)
            views.setTextViewText(R.id.widget_headline, headline)
            views.setTextViewText(R.id.widget_detail, detail)
            views.setTextViewText(R.id.widget_meta, meta)
            views.setOnClickPendingIntent(R.id.widget_root, open(context, id * 10 + 1, "talk"))
            views.setOnClickPendingIntent(R.id.widget_talk, open(context, id * 10 + 2, "talk"))
            views.setOnClickPendingIntent(R.id.widget_chats, open(context, id * 10 + 3, "chats"))
            views.setOnClickPendingIntent(R.id.widget_camera, open(context, id * 10 + 4, "camera"))
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun open(context: Context, code: Int, destination: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            putExtra("compii_dest", destination)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, CompiiWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val intent = Intent(context, CompiiWidgetProvider::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            context.sendBroadcast(intent)
        }
    }
}
