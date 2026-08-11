package com.notifmirror.android.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject

data class PairingPayload(
    val v: Int,
    val host: String,
    val port: Int,
    val secret: String,
    val name: String,
    /// SHA-256 of the WS server cert's SubjectPublicKeyInfo, base64. Only
    /// present in v=3+ payloads. Required for the wss handshake — older
    /// (plaintext-ws) QRs are no longer accepted, the user has to re-pair.
    val fp: String
) {
    fun toJson(): String = JSONObject().apply {
        put("v", v); put("host", host); put("port", port)
        put("secret", secret); put("name", name); put("fp", fp)
    }.toString()

    companion object {
        fun fromJson(text: String): PairingPayload? = runCatching {
            val o = JSONObject(text)
            // `fp` is mandatory; reject pre-TLS QRs so we don't silently fall
            // back to plaintext.
            val fp = o.optString("fp", "")
            if (fp.isEmpty()) return@runCatching null
            PairingPayload(
                v = o.getInt("v"),
                host = o.getString("host"),
                port = o.getInt("port"),
                secret = o.getString("secret"),
                name = o.getString("name"),
                fp = fp
            )
        }.getOrNull()
    }
}

class PairingStore(context: Context) {
    private val prefs by lazy {
        val key = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "encrypted_pairing",
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun save(payload: PairingPayload) {
        prefs.edit().putString(KEY_PAYLOAD, payload.toJson()).commit()
    }

    fun load(): PairingPayload? {
        val raw = prefs.getString(KEY_PAYLOAD, null) ?: return null
        return PairingPayload.fromJson(raw)
    }

    fun clear() {
        prefs.edit().remove(KEY_PAYLOAD).apply()
    }

    val isPaired: Boolean get() = load() != null

    companion object {
        private const val KEY_PAYLOAD = "payload_json"
    }
}
