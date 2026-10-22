package app.compii.compii

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The phone's screen, read and touched only when the user asks from Compii.
 * Nothing runs on a timer: MainActivity calls one method per request. Password
 * fields are never read or filled, and secure windows expose nothing to read.
 */
class CompiiAccessibilityService : AccessibilityService() {
    private var lastPackage = ""
    private var lastTitle = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString().orEmpty()
        if (pkg.isEmpty()) return
        lastPackage = pkg
        val title = event.text?.joinToString(" ")?.replace(SPACES, " ")?.trim().orEmpty()
        if (title.isNotEmpty()) lastTitle = title
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    // ---- reading -------------------------------------------------------------

    /** The app in front, its title, and the words and controls on it. */
    fun snapshot(): Map<String, Any> {
        val root = rootInActiveWindow
        val elements = mutableListOf<Map<String, Any>>()
        val seen = HashSet<String>()
        if (root != null) walk(root, 0, elements, seen)
        val pkg = root?.packageName?.toString()?.takeIf { it.isNotEmpty() } ?: lastPackage
        return mapOf(
            "package" to pkg,
            "app" to appLabel(pkg),
            "title" to if (pkg == lastPackage) lastTitle else "",
            "elements" to elements,
            "at" to System.currentTimeMillis(),
        )
    }

    private fun walk(node: AccessibilityNodeInfo, depth: Int, out: MutableList<Map<String, Any>>, seen: MutableSet<String>) {
        if (depth > 30 || out.size >= MAX_ELEMENTS) return
        if (node.isPassword) return  // never read a password field, or anything under it
        val label = labelOf(node)
        val bounds = Rect().also { node.getBoundsInScreen(it) }
        if (label.isNotEmpty() || node.isClickable || node.isScrollable || node.isEditable) {
            val key = "$label|${bounds.toShortString()}|${node.viewIdResourceName.orEmpty()}"
            if (seen.add(key)) {
                out.add(
                    mapOf(
                        "id" to out.size,
                        "text" to label.take(160),
                        "role" to role(node),
                        "clickable" to node.isClickable,
                        "scrollable" to node.isScrollable,
                        "editable" to node.isEditable,
                        "left" to bounds.left,
                        "top" to bounds.top,
                        "right" to bounds.right,
                        "bottom" to bounds.bottom,
                    ),
                )
            }
        }
        for (i in 0 until node.childCount) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            } ?: continue
            walk(child, depth + 1, out, seen)
        }
    }

    private fun labelOf(node: AccessibilityNodeInfo): String {
        val text = node.text?.toString()?.replace(SPACES, " ")?.trim().orEmpty()
        if (text.isNotEmpty()) return text
        val desc = node.contentDescription?.toString()?.replace(SPACES, " ")?.trim().orEmpty()
        if (desc.isNotEmpty()) return desc
        if (Build.VERSION.SDK_INT >= 26) {
            val hint = node.hintText?.toString()?.replace(SPACES, " ")?.trim().orEmpty()
            if (hint.isNotEmpty()) return hint
        }
        return ""
    }

    private fun role(node: AccessibilityNodeInfo): String =
        node.className?.toString()?.substringAfterLast('.')?.removeSuffix("Compat").orEmpty()

    private fun appLabel(pkg: String): String {
        if (pkg.isEmpty()) return ""
        return try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) {
            pkg
        }
    }

    // ---- touching ------------------------------------------------------------

    /** Tap the control with this visible label, or the nearest clickable parent. */
    fun tapText(label: String): Boolean {
        val wanted = tidy(label)
        if (wanted.isEmpty()) return false
        val root = rootInActiveWindow ?: return false
        val node = find(root) { n ->
            if (n.isPassword) return@find false
            val l = labelOf(n)
            l.equals(wanted, ignoreCase = true)
        } ?: find(root) { n ->
            if (n.isPassword) return@find false
            labelOf(n).contains(wanted, ignoreCase = true)
        } ?: return false
        var target: AccessibilityNodeInfo? = node
        while (target != null && !target.isClickable) target = target.parent
        if (target != null && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
        if (node.isEditable) {
            return node.performAction(AccessibilityNodeInfo.ACTION_FOCUS) ||
                node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** Put text in the field that has focus, or the first text field on screen. */
    fun type(text: String): Boolean {
        if (text.isEmpty()) return false
        val root = rootInActiveWindow ?: return false
        var field = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (field == null || !field.isEditable) field = find(root) { it.isEditable && !it.isPassword }
        if (field == null || field.isPassword) return false
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /** "down" reads further into the list; anything else goes back up. */
    fun scroll(direction: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val list = find(root) { it.isScrollable } ?: return false
        val action = if (direction.equals("down", ignoreCase = true)) {
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        } else {
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        }
        return list.performAction(action)
    }

    fun global(action: String): Boolean {
        val which = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> if (Build.VERSION.SDK_INT >= 31) GLOBAL_ACTION_NOTIFICATIONS else -1
            else -> -1
        }
        if (which < 0) return false
        return performGlobalAction(which)
    }

    /** Launch an app by its name (or package); returns the label it launched. */
    fun openApp(query: String): String? {
        val wanted = tidy(query)
        if (wanted.isEmpty()) return null
        val pm = packageManager
        val launchable = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0,
        )
        val match = launchable.firstOrNull { it.loadLabel(pm).toString().equals(wanted, ignoreCase = true) }
            ?: launchable.firstOrNull { it.loadLabel(pm).toString().contains(wanted, ignoreCase = true) }
            ?: launchable.firstOrNull { it.activityInfo.packageName.contains(wanted, ignoreCase = true) }
            ?: return null
        val go = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setComponent(ComponentName(match.activityInfo.packageName, match.activityInfo.name))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return try {
            startActivity(go)
            match.loadLabel(pm).toString()
        } catch (_: Exception) {
            null
        }
    }

    private fun find(start: AccessibilityNodeInfo, test: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        var explored = 0
        fun search(node: AccessibilityNodeInfo, depth: Int): AccessibilityNodeInfo? {
            if (depth > 30 || ++explored > MAX_SEARCH) return null
            if (test(node)) return node
            for (i in 0 until node.childCount) {
                val child = try {
                    node.getChild(i)
                } catch (_: Exception) {
                    null
                } ?: continue
                search(child, depth + 1)?.let { return it }
            }
            return null
        }
        return search(start, 0)
    }

    private fun tidy(text: String): String = text.replace(SPACES, " ").trim()

    companion object {
        private const val MAX_ELEMENTS = 120
        private const val MAX_SEARCH = 800
        private val SPACES = Regex("\\s+")

        @Volatile
        var instance: CompiiAccessibilityService? = null
            private set

        /** Turned on in Android settings, whether or not the service is bound yet. */
        fun enabled(context: Context): Boolean {
            val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager ?: return false
            val me = ComponentName(context, CompiiAccessibilityService::class.java)
            return manager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK).any {
                val info = it.resolveInfo.serviceInfo
                info.packageName == me.packageName && info.name == me.className
            }
        }
    }
}
