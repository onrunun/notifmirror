import CryptoKit
import Foundation

struct PairingPayload: Codable {
    let v: Int
    let host: String
    let port: Int
    let secret: String
    let name: String
    /// SHA-256 of the WS server cert's SubjectPublicKeyInfo, base64. The
    /// Android client pins on this so we can run a self-signed cert with
    /// no CA chain. v=3+ payloads always include it.
    let fp: String
}

/// Personal-use LAN app — pairing secret lives in `~/Library/Preferences`
/// (user-scoped plist). Keychain was overkill for this threat model and
/// prompts for the login password on every rebuild because ad-hoc code
/// signatures change.
final class Pairing {
    static let shared = Pairing()
    private let key = "pairingSecret"

    private init() {}

    func loadSecret() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    @discardableResult
    func regenerateSecret() -> String {
        let k = SymmetricKey(size: .bits256)
        let secret = k.withUnsafeBytes { Data($0) }.base64EncodedString()
        UserDefaults.standard.set(secret, forKey: key)
        // Rotate the TLS cert in lockstep — both halves of pairing identity
        // (auth secret + cert fingerprint) live in the QR, so they should
        // turn over together. A previously paired phone with just the old
        // secret cached can't reconnect with a new fp anyway.
        SelfSignedCert.shared.resetCert()
        return secret
    }

    func resetPairing() {
        UserDefaults.standard.removeObject(forKey: key)
        SelfSignedCert.shared.resetCert()
    }

    /// Constant-time secret comparison.
    func verify(_ candidate: String) -> Bool {
        guard let stored = loadSecret() else { return false }
        let a = Array(stored.utf8)
        let b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    func payload(host: String, port: Int) -> PairingPayload? {
        guard let secret = loadSecret() else { return nil }
        let name = Host.current().localizedName ?? "Mac"
        // v=3 introduces the `fp` field. If we can't compute the cert
        // fingerprint (e.g. /usr/bin/openssl missing or PEM parse failed)
        // there's no point handing out a pairing QR — the phone wouldn't
        // be able to connect over wss anyway.
        guard let fp = try? SelfSignedCert.shared.spkiFingerprintBase64() else {
            return nil
        }
        return PairingPayload(v: 3, host: host, port: port, secret: secret, name: name, fp: fp)
    }

    func payloadJSON(host: String, port: Int) -> String? {
        guard let p = payload(host: host, port: port),
              let data = try? JSONEncoder().encode(p),
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }
}

enum LocalAddress {
    /// Best-effort LAN IPv4. Returns the first non-loopback IPv4 from a Wi-Fi (en*) interface.
    static func currentLanIPv4() -> String {
        var address = "127.0.0.1"
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return address }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let p = ptr {
            let interface = p.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                    if getnameinfo(interface.ifa_addr, saLen,
                                   &hostBuf, socklen_t(hostBuf.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let candidate = String(cString: hostBuf)
                        if candidate != "127.0.0.1" {
                            address = candidate
                            break
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }
}
