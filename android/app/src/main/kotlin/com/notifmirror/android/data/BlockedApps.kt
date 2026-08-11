package com.notifmirror.android.data

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-package mute list and seen-app tracker.
 * Backed by regular SharedPreferences (no need to encrypt this — it's just
 * package names the user has muted).
 */
class BlockedApps private constructor(ctx: Context) {
    private val prefs: SharedPreferences = ctx.applicationContext
        .getSharedPreferences("blocked_apps", Context.MODE_PRIVATE)

    data class SeenApp(val pkg: String, val name: String, val lastSeen: Long, val count: Long = 0L)

    /** Called every time a notification arrives. Records pkg→name and
     *  returns true if the user has muted this package. */
    @Synchronized
    fun recordAndCheck(pkg: String, name: String): Boolean {
        val seen = loadSeen().toMutableList()
        val idx = seen.indexOfFirst { it.pkg == pkg }
        val now = System.currentTimeMillis()
        if (idx >= 0) {
            seen[idx] = seen[idx].copy(name = name, lastSeen = now, count = seen[idx].count + 1)
        } else {
            seen.add(SeenApp(pkg, name, now, 1L))
        }
        saveSeen(seen)
        return blockedSet().contains(pkg)
    }

    fun isBlocked(pkg: String): Boolean = blockedSet().contains(pkg)

    @Synchronized
    fun setBlocked(pkg: String, blocked: Boolean) {
        val s = blockedSet().toMutableSet()
        if (blocked) s.add(pkg) else s.remove(pkg)
        prefs.edit().putStringSet(KEY_BLOCKED, s).apply()
    }

    fun blockedSet(): Set<String> = prefs.getStringSet(KEY_BLOCKED, emptySet()) ?: emptySet()

    fun loadSeen(): List<SeenApp> {
        val raw = prefs.getString(KEY_SEEN, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                SeenApp(
                    o.getString("pkg"),
                    o.getString("name"),
                    o.getLong("lastSeen"),
                    o.optLong("count", 0L)
                )
            }
        } catch (_: Throwable) { emptyList() }
    }

    @Synchronized
    fun clearSeen() {
        prefs.edit().remove(KEY_SEEN).apply()
    }

    private fun saveSeen(list: List<SeenApp>) {
        val arr = JSONArray()
        list.forEach { a ->
            arr.put(JSONObject().apply {
                put("pkg", a.pkg)
                put("name", a.name)
                put("lastSeen", a.lastSeen)
                put("count", a.count)
            })
        }
        prefs.edit().putString(KEY_SEEN, arr.toString()).apply()
    }

    companion object {
        private const val KEY_BLOCKED = "blocked"
        private const val KEY_SEEN = "seen_v1"

        @Volatile private var instance: BlockedApps? = null

        fun get(context: Context): BlockedApps =
            instance ?: synchronized(this) {
                instance ?: BlockedApps(context).also { instance = it }
            }
    }
}
