package com.notifmirror.android.security

import android.util.Base64
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/**
 * Trusts ONE specific server cert, identified by the SHA-256 of its
 * SubjectPublicKeyInfo (DER). Bypasses CA-chain validation entirely — the
 * Mac server is self-signed and we hand its fingerprint to the phone via
 * the pairing QR. If pinning fails, we throw and the TLS handshake aborts.
 *
 * `expectedFpBase64` is the same `fp` field that the Mac includes in its
 * pairing payload. Comparison is constant-time.
 */
class SpkiPinTrustManager(expectedFpBase64: String) : X509TrustManager {
    private val expected: ByteArray = Base64.decode(expectedFpBase64, Base64.DEFAULT)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        // We're a client; we don't authenticate other clients.
        throw CertificateException("client cert validation not supported")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull()
            ?: throw CertificateException("server presented empty cert chain")
        // PublicKey.getEncoded() on a key pulled from an X.509 cert returns
        // the SubjectPublicKeyInfo DER (X509EncodedKeySpec format) — the
        // exact bytes the Mac side hashes to compute `fp`.
        val spkiDer = leaf.publicKey.encoded
            ?: throw CertificateException("server cert has no encodable public key")
        val sha = MessageDigest.getInstance("SHA-256").digest(spkiDer)
        if (!MessageDigest.isEqual(sha, expected)) {
            throw CertificateException("server SPKI fingerprint mismatch")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/**
 * Build an `SSLSocketFactory` that pins the given fingerprint. Call once
 * per WsClient so each client carries its own trust manager (in case the
 * pairing fp ever rotates while a stale client is being torn down).
 */
fun pinnedSslSocketFactory(expectedFpBase64: String): Pair<SSLSocketFactory, X509TrustManager> {
    val tm = SpkiPinTrustManager(expectedFpBase64)
    val ctx = SSLContext.getInstance("TLS")
    ctx.init(null, arrayOf(tm), java.security.SecureRandom())
    return ctx.socketFactory to tm
}
