package com.notifmirror.android.data

import android.content.Context
import android.content.SharedPreferences
import com.notifmirror.android.protocol.WireMessage
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-package mute list and seen-app tracker.
 * Backed by regular SharedPreferences (no need to encrypt this — it's just
 * package names the user has muted).
 *
 * The blocked list is stored as timestamped entries (pkg → blocked state +
 * last-edit time). That snapshot is what gets shipped to the paired Mac, which
 * merges "newest edit wins" per package so mutes and unmutes both propagate.
 */
class BlockedApps private constructor(ctx: Context) {
    private val prefs: SharedPreferences = ctx.applicationContext
        .getSharedPreferences("blocked_apps", Context.MODE_PRIVATE)

    data class SeenApp(val pkg: String, val name: String, val lastSeen: Long, val count: Long = 0L)

    data class BlockState(val pkg: String, val blocked: Boolean, val updatedAt: Long)

    /** Fired after every local change so the mirror core can push a fresh
     *  snapshot to the Mac. */
    var onChange: (() -> Unit)? = null

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
        val map = loadState().toMutableMap()
        map[pkg] = BlockState(pkg, blocked, System.currentTimeMillis())
        saveState(map)
        onChange?.invoke()
    }

    /** Merge a snapshot from the paired peer. For each package the newer edit
     *  wins; returns true if anything changed. Never echoes back. */
    @Synchronized
    fun applyRemote(entries: List<WireMessage.BlocklistEntry>): Boolean {
        val map = loadState().toMutableMap()
        var changed = false
        for (e in entries) {
            val cur = map[e.pkg]
            if (cur == null || e.updatedAt > cur.updatedAt) {
                map[e.pkg] = BlockState(e.pkg, e.blocked, e.updatedAt)
                changed = true
            }
        }
        if (changed) saveState(map)
        return changed
    }

    fun snapshot(): List<WireMessage.BlocklistEntry> =
        loadState().values.map { WireMessage.BlocklistEntry(it.pkg, it.blocked, it.updatedAt) }

    fun blockedSet(): Set<String> =
        loadState().values.filter { it.blocked }.map { it.pkg }.toSet()

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

    private fun loadState(): Map<String, BlockState> {
        val raw = prefs.getString(KEY_STATE, null) ?: return emptyMap()
        return try {
            val arr = JSONArray(raw)
            val out = HashMap<String, BlockState>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val s = BlockState(
                    o.getString("pkg"),
                    o.optBoolean("blocked"),
                    o.optLong("updatedAt")
                )
                out[s.pkg] = s
            }
            out
        } catch (_: Throwable) { emptyMap() }
    }

    private fun saveState(map: Map<String, BlockState>) {
        val arr = JSONArray()
        map.values.forEach { s ->
            arr.put(JSONObject().apply {
                put("pkg", s.pkg)
                put("blocked", s.blocked)
                put("updatedAt", s.updatedAt)
            })
        }
        prefs.edit().putString(KEY_STATE, arr.toString()).apply()
    }

    companion object {
        private const val KEY_SEEN = "seen_v1"
        private const val KEY_STATE = "blocked_v2"

        @Volatile private var instance: BlockedApps? = null

        fun get(context: Context): BlockedApps =
            instance ?: synchronized(this) {
                instance ?: BlockedApps(context).also { instance = it }
            }
    }
}
