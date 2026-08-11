import Foundation

enum WireError: Error {
    case malformed(String)
}

struct ActionDescriptor: Codable, Hashable {
    let id: String
    let title: String
    let isReply: Bool
}

enum WireMessage {
    case hello(secret: String, deviceName: String, proto: Int, features: [String])
    case helloAck(accepted: Bool, serverName: String, features: [String], dataPort: Int)
    case posted(Posted)
    case removed(key: String)
    case dismiss(key: String)
    case action(key: String, actionId: String, text: String?)

    case clip(text: String, origin: String, seq: Int)

    case mediaState(MediaState)
    case mediaCmd(cmd: String, value: Int?)

    case batteryState(BatteryState)

    case fileOffer(FileOffer)
    case fileAccept(xid: String)
    case fileReject(xid: String, reason: String)
    case fileChunk(xid: String, offset: Int64, data: String, last: Bool)
    case fileDone(xid: String)
    case fileAck(xid: String, ok: Bool, error: String?)
    case fileCancel(xid: String, reason: String)

    // Phone file browse — operates directly over the paired WebSocket so the
    // user doesn't need adb / wireless debugging. Each request carries a
    // `reqId` (short random string) that its response(s) echo back for
    // correlation. Read/write stream data via `fsChunk` messages.
    case fsList(reqId: String, path: String)
    case fsListResult(reqId: String, path: String, entries: [FsEntry], error: String?)
    case fsDelete(reqId: String, path: String)
    case fsMkdir(reqId: String, path: String)
    case fsRename(reqId: String, from: String, to: String)
    case fsOpResult(reqId: String, ok: Bool, error: String?)
    case fsDisk(reqId: String, path: String)
    case fsDiskResult(reqId: String, free: Int64, total: Int64, error: String?)
    case fsDu(reqId: String, path: String)
    case fsDuResult(reqId: String, path: String, totalSize: Int64, entries: [FsDuEntry], error: String?)
    case fsRead(reqId: String, path: String)
    case fsReadResult(reqId: String, size: Int64, error: String?)
    case fsWrite(reqId: String, path: String, size: Int64)
    case fsWriteReady(reqId: String, error: String?)
    case fsChunk(reqId: String, offset: Int64, data: String, last: Bool)
    /// Mac → phone: abandon an in-flight pull (fs_read) or push (fs_write).
    /// The phone should stop streaming for this reqId so Wi-Fi isn't wasted
    /// on a transfer the Mac has already given up on. No response expected.
    case fsCancel(reqId: String, reason: String)

    /// Mac → phone: ask Android to post a real local notification from the
    /// NotifMirror app package, so its NotificationListener catches it and
    /// the normal `posted` round-trip exercises the full mirror pipeline.
    /// Mac correlates the response by looking for `reqId` in the returned
    /// `posted.text`.
    case testRequest(reqId: String)

    case ping
    case pong
    case error(code: String, msg: String)

    /// Received a valid JSON frame with an unrecognised `t` value. Callers
    /// should silently ignore. This lets either peer roll new message types
    /// without breaking older peers.
    case unknown(String)

    struct Posted: Codable {
        let key: String
        let pkg: String
        let app: String
        let title: String?
        let text: String?
        let subText: String?
        let appIcon: String?
        let largeIcon: String?
        let picture: String?
        let postTime: Int64
        let silent: Bool
        let actions: [ActionDescriptor]
    }

    struct MediaState {
        let pkg: String?
        let app: String?
        let title: String?
        let artist: String?
        let album: String?
        let artwork: String?
        let playing: Bool
        let positionMs: Int64
        let durationMs: Int64
        let canPause: Bool
        let canSkipNext: Bool
        let canSkipPrev: Bool
        let volume: Int
        let maxVolume: Int
        let updatedAt: Int64
    }

    struct FileOffer {
        let xid: String
        let name: String
        let size: Int64
        let mime: String?
        let sha256: String?
    }

    /// Phone battery snapshot. `level == -1` means the OS reported no value.
    struct BatteryState: Equatable {
        let level: Int
        let charging: Bool
        let status: String
        let plugged: String
        let temperatureC: Double?
        let voltageMv: Int?
        let low: Bool
        let updatedAt: Int64
    }

    struct FsEntry: Hashable {
        enum Kind: String { case dir, file, link, other }
        let name: String
        let kind: Kind
        let size: Int64
        let mtime: Int64   // seconds since epoch
    }

    /// One immediate child of an `fs_du` scan. `totalSize` is recursive for
    /// directories (entire subtree on the phone, in bytes), equal to file
    /// size for files, 0 for symlinks (not followed).
    struct FsDuEntry: Hashable, Identifiable {
        let name: String
        let kind: FsEntry.Kind
        let totalSize: Int64
        let fileCount: Int64
        var id: String { name }
    }
}

enum WireCodec {
    static let protocolVersion = 2
    /// Older peers still speak proto=1. We accept both on the server side.
    static let minAcceptedProtocol = 1

    static func encode(_ message: WireMessage) throws -> Data {
        var dict: [String: Any] = ["v": protocolVersion]
        switch message {
        case let .hello(secret, deviceName, proto, features):
            dict["t"] = "hello"
            dict["secret"] = secret
            dict["deviceName"] = deviceName
            dict["proto"] = proto
            if !features.isEmpty { dict["features"] = features }
        case let .helloAck(accepted, serverName, features, dataPort):
            dict["t"] = "hello_ack"
            dict["accepted"] = accepted
            dict["serverName"] = serverName
            if !features.isEmpty { dict["features"] = features }
            if dataPort > 0 { dict["dataPort"] = dataPort }
        case let .posted(p):
            dict["t"] = "posted"
            dict["key"] = p.key
            dict["pkg"] = p.pkg
            dict["app"] = p.app
            dict["title"] = p.title as Any
            dict["text"] = p.text as Any
            dict["subText"] = p.subText as Any
            dict["appIcon"] = p.appIcon as Any
            dict["largeIcon"] = p.largeIcon as Any
            dict["picture"] = p.picture as Any
            dict["postTime"] = p.postTime
            dict["silent"] = p.silent
            dict["actions"] = p.actions.map { ["id": $0.id, "title": $0.title, "isReply": $0.isReply] }
        case let .removed(key):
            dict["t"] = "removed"
            dict["key"] = key
        case let .dismiss(key):
            dict["t"] = "dismiss"
            dict["key"] = key
        case let .action(key, actionId, text):
            dict["t"] = "action"
            dict["key"] = key
            dict["actionId"] = actionId
            if let text { dict["text"] = text }
        case let .clip(text, origin, seq):
            dict["t"] = "clip"
            dict["text"] = text
            dict["origin"] = origin
            dict["seq"] = seq
        case let .mediaState(m):
            dict["t"] = "media_state"
            dict["pkg"] = m.pkg as Any
            dict["app"] = m.app as Any
            dict["title"] = m.title as Any
            dict["artist"] = m.artist as Any
            dict["album"] = m.album as Any
            dict["artwork"] = m.artwork as Any
            dict["playing"] = m.playing
            dict["positionMs"] = m.positionMs
            dict["durationMs"] = m.durationMs
            dict["canPause"] = m.canPause
            dict["canSkipNext"] = m.canSkipNext
            dict["canSkipPrev"] = m.canSkipPrev
            dict["volume"] = m.volume
            dict["maxVolume"] = m.maxVolume
            dict["updatedAt"] = m.updatedAt
        case let .mediaCmd(cmd, value):
            dict["t"] = "media_cmd"
            dict["cmd"] = cmd
            if let value { dict["value"] = value }
        case let .batteryState(b):
            dict["t"] = "battery_state"
            dict["level"] = b.level
            dict["charging"] = b.charging
            dict["status"] = b.status
            dict["plugged"] = b.plugged
            dict["temperatureC"] = b.temperatureC as Any
            dict["voltageMv"] = b.voltageMv as Any
            dict["low"] = b.low
            dict["updatedAt"] = b.updatedAt
        case let .fileOffer(f):
            dict["t"] = "file_offer"
            dict["xid"] = f.xid
            dict["name"] = f.name
            dict["size"] = f.size
            if let m = f.mime { dict["mime"] = m }
            if let s = f.sha256 { dict["sha256"] = s }
        case let .fileAccept(xid):
            dict["t"] = "file_accept"; dict["xid"] = xid
        case let .fileReject(xid, reason):
            dict["t"] = "file_reject"; dict["xid"] = xid; dict["reason"] = reason
        case let .fileChunk(xid, offset, data, last):
            dict["t"] = "file_chunk"
            dict["xid"] = xid
            dict["offset"] = offset
            dict["data"] = data
            dict["last"] = last
        case let .fileDone(xid):
            dict["t"] = "file_done"; dict["xid"] = xid
        case let .fileAck(xid, ok, err):
            dict["t"] = "file_ack"; dict["xid"] = xid; dict["ok"] = ok
            if let err { dict["error"] = err }
        case let .fileCancel(xid, reason):
            dict["t"] = "file_cancel"; dict["xid"] = xid; dict["reason"] = reason
        case let .fsList(reqId, path):
            dict["t"] = "fs_list"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsListResult(reqId, path, entries, error):
            dict["t"] = "fs_list_result"
            dict["reqId"] = reqId
            dict["path"] = path
            dict["entries"] = entries.map { [
                "name": $0.name,
                "kind": $0.kind.rawValue,
                "size": $0.size,
                "mtime": $0.mtime,
            ] as [String: Any] }
            if let e = error { dict["error"] = e }
        case let .fsDelete(reqId, path):
            dict["t"] = "fs_delete"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsMkdir(reqId, path):
            dict["t"] = "fs_mkdir"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsRename(reqId, from, to):
            dict["t"] = "fs_rename"; dict["reqId"] = reqId
            dict["from"] = from; dict["to"] = to
        case let .fsOpResult(reqId, ok, error):
            dict["t"] = "fs_op_result"; dict["reqId"] = reqId; dict["ok"] = ok
            if let e = error { dict["error"] = e }
        case let .fsDisk(reqId, path):
            dict["t"] = "fs_disk"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsDiskResult(reqId, free, total, error):
            dict["t"] = "fs_disk_result"
            dict["reqId"] = reqId; dict["free"] = free; dict["total"] = total
            if let e = error { dict["error"] = e }
        case let .fsDu(reqId, path):
            dict["t"] = "fs_du"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsDuResult(reqId, path, totalSize, entries, error):
            dict["t"] = "fs_du_result"
            dict["reqId"] = reqId
            dict["path"] = path
            dict["totalSize"] = totalSize
            dict["entries"] = entries.map { [
                "name": $0.name,
                "kind": $0.kind.rawValue,
                "totalSize": $0.totalSize,
                "fileCount": $0.fileCount,
            ] as [String: Any] }
            if let e = error { dict["error"] = e }
        case let .fsRead(reqId, path):
            dict["t"] = "fs_read"; dict["reqId"] = reqId; dict["path"] = path
        case let .fsReadResult(reqId, size, error):
            dict["t"] = "fs_read_result"; dict["reqId"] = reqId; dict["size"] = size
            if let e = error { dict["error"] = e }
        case let .fsWrite(reqId, path, size):
            dict["t"] = "fs_write"; dict["reqId"] = reqId
            dict["path"] = path; dict["size"] = size
        case let .fsWriteReady(reqId, error):
            dict["t"] = "fs_write_ready"; dict["reqId"] = reqId
            if let e = error { dict["error"] = e }
        case let .fsChunk(reqId, offset, data, last):
            dict["t"] = "fs_chunk"
            dict["reqId"] = reqId
            dict["offset"] = offset
            dict["data"] = data
            dict["last"] = last
        case let .fsCancel(reqId, reason):
            dict["t"] = "fs_cancel"; dict["reqId"] = reqId; dict["reason"] = reason
        case let .testRequest(reqId):
            dict["t"] = "test_request"; dict["reqId"] = reqId
        case .ping:
            dict["t"] = "ping"
        case .pong:
            dict["t"] = "pong"
        case let .error(code, msg):
            dict["t"] = "error"
            dict["code"] = code
            dict["msg"] = msg
        case .unknown:
            // Never encoded outbound.
            throw WireError.malformed("unknown cannot be encoded")
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    static func decode(_ data: Data) throws -> WireMessage {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any],
              let type = dict["t"] as? String
        else {
            throw WireError.malformed("not a JSON object with 't'")
        }
        switch type {
        case "hello":
            guard let secret = dict["secret"] as? String,
                  let deviceName = dict["deviceName"] as? String,
                  let proto = dict["proto"] as? Int
            else { throw WireError.malformed("hello missing fields") }
            let features = (dict["features"] as? [String]) ?? []
            return .hello(secret: secret, deviceName: deviceName, proto: proto, features: features)
        case "hello_ack":
            let accepted = (dict["accepted"] as? Bool) ?? false
            let name = (dict["serverName"] as? String) ?? ""
            let features = (dict["features"] as? [String]) ?? []
            let dataPort = (dict["dataPort"] as? Int) ?? 0
            return .helloAck(accepted: accepted, serverName: name, features: features, dataPort: dataPort)
        case "posted":
            guard let key = dict["key"] as? String,
                  let pkg = dict["pkg"] as? String,
                  let app = dict["app"] as? String
            else { throw WireError.malformed("posted missing fields") }
            let actionsRaw = (dict["actions"] as? [[String: Any]]) ?? []
            let actions: [ActionDescriptor] = actionsRaw.compactMap { a in
                guard let id = a["id"] as? String,
                      let title = a["title"] as? String
                else { return nil }
                let isReply = (a["isReply"] as? Bool) ?? false
                return ActionDescriptor(id: id, title: title, isReply: isReply)
            }
            let p = WireMessage.Posted(
                key: key,
                pkg: pkg,
                app: app,
                title: dict["title"] as? String,
                text: dict["text"] as? String,
                subText: dict["subText"] as? String,
                appIcon: dict["appIcon"] as? String,
                largeIcon: dict["largeIcon"] as? String,
                picture: dict["picture"] as? String,
                postTime: (dict["postTime"] as? Int64) ?? Int64((dict["postTime"] as? Int) ?? 0),
                silent: (dict["silent"] as? Bool) ?? false,
                actions: actions
            )
            return .posted(p)
        case "removed":
            guard let key = dict["key"] as? String else { throw WireError.malformed("removed missing key") }
            return .removed(key: key)
        case "dismiss":
            guard let key = dict["key"] as? String else { throw WireError.malformed("dismiss missing key") }
            return .dismiss(key: key)
        case "action":
            guard let key = dict["key"] as? String,
                  let actionId = dict["actionId"] as? String
            else { throw WireError.malformed("action missing fields") }
            return .action(key: key, actionId: actionId, text: dict["text"] as? String)
        case "clip":
            guard let text = dict["text"] as? String else { throw WireError.malformed("clip missing text") }
            let origin = (dict["origin"] as? String) ?? "unknown"
            let seq = (dict["seq"] as? Int) ?? 0
            return .clip(text: text, origin: origin, seq: seq)
        case "media_state":
            let m = WireMessage.MediaState(
                pkg: dict["pkg"] as? String,
                app: dict["app"] as? String,
                title: dict["title"] as? String,
                artist: dict["artist"] as? String,
                album: dict["album"] as? String,
                artwork: dict["artwork"] as? String,
                playing: (dict["playing"] as? Bool) ?? false,
                positionMs: (dict["positionMs"] as? Int64) ?? Int64((dict["positionMs"] as? Int) ?? 0),
                durationMs: (dict["durationMs"] as? Int64) ?? Int64((dict["durationMs"] as? Int) ?? 0),
                canPause: (dict["canPause"] as? Bool) ?? false,
                canSkipNext: (dict["canSkipNext"] as? Bool) ?? false,
                canSkipPrev: (dict["canSkipPrev"] as? Bool) ?? false,
                volume: (dict["volume"] as? Int) ?? 0,
                maxVolume: (dict["maxVolume"] as? Int) ?? 0,
                updatedAt: (dict["updatedAt"] as? Int64) ?? Int64((dict["updatedAt"] as? Int) ?? 0)
            )
            return .mediaState(m)
        case "media_cmd":
            guard let cmd = dict["cmd"] as? String else { throw WireError.malformed("media_cmd missing cmd") }
            return .mediaCmd(cmd: cmd, value: dict["value"] as? Int)
        case "battery_state":
            let level = (dict["level"] as? Int) ?? -1
            let temp: Double? = (dict["temperatureC"] as? Double)
                ?? (dict["temperatureC"] as? Int).map(Double.init)
            let b = WireMessage.BatteryState(
                level: level,
                charging: (dict["charging"] as? Bool) ?? false,
                status: (dict["status"] as? String) ?? "unknown",
                plugged: (dict["plugged"] as? String) ?? "unknown",
                temperatureC: temp,
                voltageMv: dict["voltageMv"] as? Int,
                low: (dict["low"] as? Bool) ?? false,
                updatedAt: (dict["updatedAt"] as? Int64) ?? Int64((dict["updatedAt"] as? Int) ?? 0)
            )
            return .batteryState(b)
        case "file_offer":
            guard let xid = dict["xid"] as? String,
                  let name = dict["name"] as? String
            else { throw WireError.malformed("file_offer missing fields") }
            let size = (dict["size"] as? Int64) ?? Int64((dict["size"] as? Int) ?? 0)
            return .fileOffer(.init(
                xid: xid, name: name, size: size,
                mime: dict["mime"] as? String,
                sha256: dict["sha256"] as? String
            ))
        case "file_accept":
            guard let xid = dict["xid"] as? String else { throw WireError.malformed("file_accept missing xid") }
            return .fileAccept(xid: xid)
        case "file_reject":
            guard let xid = dict["xid"] as? String else { throw WireError.malformed("file_reject missing xid") }
            return .fileReject(xid: xid, reason: (dict["reason"] as? String) ?? "unknown")
        case "file_chunk":
            guard let xid = dict["xid"] as? String,
                  let data = dict["data"] as? String
            else { throw WireError.malformed("file_chunk missing fields") }
            let offset = (dict["offset"] as? Int64) ?? Int64((dict["offset"] as? Int) ?? 0)
            let last = (dict["last"] as? Bool) ?? false
            return .fileChunk(xid: xid, offset: offset, data: data, last: last)
        case "file_done":
            guard let xid = dict["xid"] as? String else { throw WireError.malformed("file_done missing xid") }
            return .fileDone(xid: xid)
        case "file_ack":
            guard let xid = dict["xid"] as? String else { throw WireError.malformed("file_ack missing xid") }
            return .fileAck(xid: xid, ok: (dict["ok"] as? Bool) ?? false, error: dict["error"] as? String)
        case "file_cancel":
            guard let xid = dict["xid"] as? String else { throw WireError.malformed("file_cancel missing xid") }
            return .fileCancel(xid: xid, reason: (dict["reason"] as? String) ?? "unknown")
        case "fs_list":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_list missing fields") }
            return .fsList(reqId: reqId, path: path)
        case "fs_list_result":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_list_result missing fields") }
            let rawEntries = (dict["entries"] as? [[String: Any]]) ?? []
            let entries: [WireMessage.FsEntry] = rawEntries.compactMap { e in
                guard let name = e["name"] as? String,
                      let kindRaw = e["kind"] as? String,
                      let kind = WireMessage.FsEntry.Kind(rawValue: kindRaw)
                else { return nil }
                let size = (e["size"] as? Int64) ?? Int64((e["size"] as? Int) ?? 0)
                let mtime = (e["mtime"] as? Int64) ?? Int64((e["mtime"] as? Int) ?? 0)
                return WireMessage.FsEntry(name: name, kind: kind, size: size, mtime: mtime)
            }
            return .fsListResult(reqId: reqId, path: path, entries: entries, error: dict["error"] as? String)
        case "fs_delete":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_delete missing fields") }
            return .fsDelete(reqId: reqId, path: path)
        case "fs_mkdir":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_mkdir missing fields") }
            return .fsMkdir(reqId: reqId, path: path)
        case "fs_rename":
            guard let reqId = dict["reqId"] as? String,
                  let from = dict["from"] as? String,
                  let to = dict["to"] as? String
            else { throw WireError.malformed("fs_rename missing fields") }
            return .fsRename(reqId: reqId, from: from, to: to)
        case "fs_op_result":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("fs_op_result missing reqId") }
            return .fsOpResult(reqId: reqId,
                               ok: (dict["ok"] as? Bool) ?? false,
                               error: dict["error"] as? String)
        case "fs_disk":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_disk missing fields") }
            return .fsDisk(reqId: reqId, path: path)
        case "fs_disk_result":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("fs_disk_result missing reqId") }
            let free = (dict["free"] as? Int64) ?? Int64((dict["free"] as? Int) ?? 0)
            let total = (dict["total"] as? Int64) ?? Int64((dict["total"] as? Int) ?? 0)
            return .fsDiskResult(reqId: reqId, free: free, total: total, error: dict["error"] as? String)
        case "fs_du":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_du missing fields") }
            return .fsDu(reqId: reqId, path: path)
        case "fs_du_result":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_du_result missing fields") }
            let totalSize = (dict["totalSize"] as? Int64) ?? Int64((dict["totalSize"] as? Int) ?? 0)
            let rawEntries = (dict["entries"] as? [[String: Any]]) ?? []
            let entries: [WireMessage.FsDuEntry] = rawEntries.compactMap { e in
                guard let name = e["name"] as? String,
                      let kindRaw = e["kind"] as? String,
                      let kind = WireMessage.FsEntry.Kind(rawValue: kindRaw)
                else { return nil }
                let total = (e["totalSize"] as? Int64) ?? Int64((e["totalSize"] as? Int) ?? 0)
                let count = (e["fileCount"] as? Int64) ?? Int64((e["fileCount"] as? Int) ?? 0)
                return WireMessage.FsDuEntry(name: name, kind: kind, totalSize: total, fileCount: count)
            }
            return .fsDuResult(reqId: reqId, path: path, totalSize: totalSize,
                               entries: entries, error: dict["error"] as? String)
        case "fs_read":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_read missing fields") }
            return .fsRead(reqId: reqId, path: path)
        case "fs_read_result":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("fs_read_result missing reqId") }
            let size = (dict["size"] as? Int64) ?? Int64((dict["size"] as? Int) ?? 0)
            return .fsReadResult(reqId: reqId, size: size, error: dict["error"] as? String)
        case "fs_write":
            guard let reqId = dict["reqId"] as? String,
                  let path = dict["path"] as? String
            else { throw WireError.malformed("fs_write missing fields") }
            let size = (dict["size"] as? Int64) ?? Int64((dict["size"] as? Int) ?? 0)
            return .fsWrite(reqId: reqId, path: path, size: size)
        case "fs_write_ready":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("fs_write_ready missing reqId") }
            return .fsWriteReady(reqId: reqId, error: dict["error"] as? String)
        case "fs_chunk":
            guard let reqId = dict["reqId"] as? String,
                  let data = dict["data"] as? String
            else { throw WireError.malformed("fs_chunk missing fields") }
            let offset = (dict["offset"] as? Int64) ?? Int64((dict["offset"] as? Int) ?? 0)
            let last = (dict["last"] as? Bool) ?? false
            return .fsChunk(reqId: reqId, offset: offset, data: data, last: last)
        case "fs_cancel":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("fs_cancel missing reqId") }
            return .fsCancel(reqId: reqId, reason: (dict["reason"] as? String) ?? "abandoned")
        case "test_request":
            guard let reqId = dict["reqId"] as? String
            else { throw WireError.malformed("test_request missing reqId") }
            return .testRequest(reqId: reqId)
        case "ping":
            return .ping
        case "pong":
            return .pong
        case "error":
            return .error(
                code: (dict["code"] as? String) ?? "unknown",
                msg: (dict["msg"] as? String) ?? ""
            )
        default:
            return .unknown(type)
        }
    }
}
