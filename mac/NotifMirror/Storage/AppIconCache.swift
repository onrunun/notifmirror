import Foundation

/// Caches base64 PNGs of app icons so the phone only needs to send each
/// app's icon once per pairing.
final class AppIconCache {
    private let directory: URL
    private let memCache = NSCache<NSString, NSString>()

    init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("NotifMirror/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    func store(pkg: String, base64: String) {
        memCache.setObject(base64 as NSString, forKey: pkg as NSString)
        let url = directory.appendingPathComponent(pkg).appendingPathExtension("b64")
        try? base64.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func base64(forPkg pkg: String) -> String? {
        if let cached = memCache.object(forKey: pkg as NSString) as String? {
            return cached
        }
        let url = directory.appendingPathComponent(pkg).appendingPathExtension("b64")
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) {
            memCache.setObject(s as NSString, forKey: pkg as NSString)
            return s
        }
        return nil
    }
}
