import CryptoKit
import Foundation
import Security

/// Self-signed leaf cert + private key for the WS server. Minted once on
/// first launch by shelling out to `/usr/bin/openssl` (LibreSSL on macOS),
/// then cached in UserDefaults alongside the pairing secret. The Android
/// client pins the SHA-256 of the cert's SubjectPublicKeyInfo (advertised
/// as `fp` in the pairing QR), so the cert can be totally untrusted by any
/// CA — pinning is the only thing that matters.
///
/// Lives in UserDefaults rather than Keychain for the same reason the
/// pairing secret does: ad-hoc-signed dev builds get a fresh code signature
/// every rebuild, which would re-prompt for the login keychain password.
final class SelfSignedCert {
    static let shared = SelfSignedCert()

    private let certKey = "tlsCertPEM"
    private let keyKey  = "tlsKeyPEM"

    private let lock = NSLock()
    /// Cached SecIdentity so we only pay the PEM parse / key import cost once
    /// per process lifetime, not on every WsServer (re)start. Reset by
    /// `resetCert()` so a rotation forces a fresh import.
    private var cachedIdentity: SecIdentity?

    private init() {}

    /// Returns a SecIdentity backed by the cached cert+key, minting them
    /// on first call. Throws on any system-level failure (openssl missing,
    /// PEM parse, identity import). Safe to call from any thread; serialised
    /// internally so concurrent callers don't double-mint.
    func identity() throws -> SecIdentity {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedIdentity { return cached }
        let (certPEM, keyPEM) = try loadOrMint()
        let id = try makeIdentity(certPEM: certPEM, keyPEM: keyPEM)
        cachedIdentity = id
        return id
    }

    /// SHA-256 of the cert's SubjectPublicKeyInfo (DER), base64. This is
    /// what the Android client pins on. Stable across reboots; only
    /// changes when `resetCert()` is called.
    func spkiFingerprintBase64() throws -> String {
        let certPEM: String = try {
            lock.lock(); defer { lock.unlock() }
            let (c, _) = try loadOrMint()
            return c
        }()
        let der = try pemToDER(certPEM, header: "CERTIFICATE")
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertError.parse("SecCertificateCreateWithData failed")
        }
        let spkiDER = try Self.spkiDER(from: cert)
        let digest = SHA256.hash(data: spkiDER)
        return Data(digest).base64EncodedString()
    }

    /// Wipe the cached cert+key so the next call mints a fresh pair. The
    /// fingerprint will change, so any paired phone has to re-scan the QR.
    /// Hooked to the same "Reset pairing" button that rotates the secret.
    func resetCert() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: certKey)
        UserDefaults.standard.removeObject(forKey: keyKey)
        cachedIdentity = nil
    }

    // MARK: - Internals

    private func loadOrMint() throws -> (String, String) {
        if let c = UserDefaults.standard.string(forKey: certKey),
           let k = UserDefaults.standard.string(forKey: keyKey),
           !c.isEmpty, !k.isEmpty {
            return (c, k)
        }
        let (c, k) = try mintWithOpenSSL()
        UserDefaults.standard.set(c, forKey: certKey)
        UserDefaults.standard.set(k, forKey: keyKey)
        return (c, k)
    }

    private func mintWithOpenSSL() throws -> (String, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notifmirror-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let keyURL = tmp.appendingPathComponent("key.pem")
        let certURL = tmp.appendingPathComponent("cert.pem")

        // RSA 2048, self-signed, 100-year validity. The original reason we
        // avoided EC P-256 was an uncatchable ObjC NSException on macOS 26.4
        // inside the PKCS#12 import path, which makeIdentity no longer uses —
        // EC would work now, but switching means new installs hand the phone
        // a different fingerprint, and RSA costs nothing at this scale.
        // Subject is cosmetic; Android pins on the SPKI hash, not CN/SAN.
        let proc = Process()
        proc.launchPath = "/usr/bin/openssl"
        proc.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "36500",
            "-nodes",
            "-subj", "/CN=NotifMirror"
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw CertError.openssl("openssl exited \(proc.terminationStatus): \(err)")
        }

        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        return (certPEM, keyPEM)
    }

    private func makeIdentity(certPEM: String, keyPEM: String) throws -> SecIdentity {
        // Build the SecIdentity straight from the PEMs. No PKCS#12, no
        // keychain: SecPKCS12Import imports into the login keychain, which
        // re-prompts "NotifMirror wants to sign using key" on every launch
        // (each import creates a fresh keychain item the ACL doesn't know).
        // `SecKeyCreateWithData` + `SecIdentityCreate` are both public API
        // since macOS 10.12 and keep everything in memory.
        let certDER = try pemToDER(certPEM, header: "CERTIFICATE")
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw CertError.parse("SecCertificateCreateWithData failed")
        }
        let keyDER = try rsaPrivateKeyDER(fromPEM: keyPEM)
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let key = SecKeyCreateWithData(keyDER as CFData, keyAttrs as CFDictionary, nil) else {
            throw CertError.parse("SecKeyCreateWithData failed")
        }
        guard let identity = SecIdentityCreate(nil, cert, key) else {
            throw CertError.parse("SecIdentityCreate failed")
        }
        return identity
    }

    /// The RSA private key as PKCS#1 DER, which is the only form
    /// `SecKeyCreateWithData` accepts — on macOS 26.5 it rejects the PKCS#8
    /// wrapper (errSecParam -50) even though both DERs are valid. LibreSSL's
    /// `openssl req -newkey` writes PKCS#8, whose `privateKey` OCTET STRING
    /// payload is exactly the PKCS#1 DER we want. Already-PKCS#1 PEMs (older
    /// stored keys) pass straight through.
    private func rsaPrivateKeyDER(fromPEM pem: String) throws -> Data {
        if pem.contains("BEGIN RSA PRIVATE KEY") {
            return try pemToDER(pem, header: "RSA PRIVATE KEY")
        }
        let pkcs8 = try pemToDER(pem, header: "PRIVATE KEY")
        let bytes = [UInt8](pkcs8)
        guard let outer = Self.parseSEQ(bytes, offset: 0) else {
            throw CertError.parse("PKCS#8 outer SEQUENCE missing")
        }
        var p = outer.contentStart
        let end = outer.contentStart + outer.contentLength
        while p < end {
            guard let any = Self.parseAny(bytes, offset: p) else { break }
            if any.tag == 0x04 {  // privateKey OCTET STRING wraps the PKCS#1 DER
                return Data(bytes[any.contentStart..<any.contentStart + any.contentLength])
            }
            p = any.contentStart + any.contentLength
        }
        throw CertError.parse("PKCS#8 privateKey OCTET STRING not found")
    }

    // MARK: - DER / SPKI helpers

    private func pemToDER(_ pem: String, header: String) throws -> Data {
        let begin = "-----BEGIN \(header)-----"
        let end = "-----END \(header)-----"
        guard let r1 = pem.range(of: begin), let r2 = pem.range(of: end) else {
            throw CertError.parse("PEM markers for \(header) missing")
        }
        let body = pem[r1.upperBound..<r2.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: body) else {
            throw CertError.parse("PEM body not base64")
        }
        return data
    }

    /// Pull the SubjectPublicKeyInfo (DER) out of an X.509 certificate.
    /// We can't use SecCertificateCopyKey + SecKeyCopyExternalRepresentation
    /// because the latter strips the AlgorithmIdentifier wrapper, which is
    /// part of what we want to fingerprint (matching what OkHttp's
    /// CertificatePinner does on Android). So we walk the DER ourselves.
    private static func spkiDER(from cert: SecCertificate) throws -> Data {
        let certData = SecCertificateCopyData(cert) as Data
        // X.509 outer SEQUENCE → tbsCertificate (SEQUENCE) → its 7th element
        // is SubjectPublicKeyInfo. Rather than walk every field, parse just
        // enough DER to find the SPKI by matching its SEQUENCE that begins
        // with the standard EC OID prefix.
        let bytes = [UInt8](certData)
        guard let outer = parseSEQ(bytes, offset: 0) else {
            throw CertError.parse("X.509 outer SEQUENCE missing")
        }
        guard let tbs = parseSEQ(bytes, offset: outer.contentStart) else {
            throw CertError.parse("tbsCertificate SEQUENCE missing")
        }
        // Walk the TBS children looking for a SEQUENCE whose first child is
        // a SEQUENCE (the AlgorithmIdentifier) and whose second child is a
        // BIT STRING — that's SubjectPublicKeyInfo.
        var p = tbs.contentStart
        let tbsEnd = tbs.contentStart + tbs.contentLength
        while p < tbsEnd {
            guard let any = parseAny(bytes, offset: p) else { break }
            if any.tag == 0x30 {
                // Candidate SEQUENCE — check children.
                if let alg = parseSEQ(bytes, offset: any.contentStart) {
                    let bsOff = alg.contentStart + alg.contentLength
                    if bsOff < any.contentStart + any.contentLength,
                       bytes.indices.contains(bsOff),
                       bytes[bsOff] == 0x03 {  // BIT STRING
                        let total = (any.contentStart + any.contentLength) - any.headerStart
                        return Data(bytes[any.headerStart..<any.headerStart + total])
                    }
                }
            }
            p = any.contentStart + any.contentLength
        }
        throw CertError.parse("SubjectPublicKeyInfo not found")
    }

    private struct DERField {
        let tag: UInt8
        /// Offset of the tag byte.
        let headerStart: Int
        /// Offset of the first content byte.
        let contentStart: Int
        let contentLength: Int
    }

    private static func parseSEQ(_ b: [UInt8], offset: Int) -> DERField? {
        guard let f = parseAny(b, offset: offset), f.tag == 0x30 else { return nil }
        return f
    }

    private static func parseAny(_ b: [UInt8], offset: Int) -> DERField? {
        guard offset + 1 < b.count else { return nil }
        let tag = b[offset]
        var p = offset + 1
        let first = b[p]; p += 1
        let length: Int
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard n > 0, n <= 4, p + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n {
                v = (v << 8) | Int(b[p]); p += 1
            }
            length = v
        }
        guard p + length <= b.count else { return nil }
        return DERField(tag: tag, headerStart: offset, contentStart: p, contentLength: length)
    }
}

enum CertError: Error {
    case openssl(String)
    case parse(String)
}
