@testable import NotifMirror
import XCTest

/// Round-trip tests for the wire codec. These mirror the Android-side JVM
/// suite (android/.../WireCodecTest.kt) so a protocol change on either
/// platform is caught by the other platform's CI.
final class WireCodecTests: XCTestCase {

    private func roundTrip(_ message: WireMessage) throws -> WireMessage {
        let data = try WireCodec.encode(message)
        return try WireCodec.decode(data)
    }

    func testHelloRoundTrip() throws {
        let m = try roundTrip(.hello(secret: "s3cr3t", deviceName: "Pixel 8", proto: 2, features: ["clip", "media", "file"]))
        guard case let .hello(secret, deviceName, proto, features) = m else {
            return XCTFail("expected hello, got \(m)")
        }
        XCTAssertEqual(secret, "s3cr3t")
        XCTAssertEqual(deviceName, "Pixel 8")
        XCTAssertEqual(proto, 2)
        XCTAssertEqual(features, ["clip", "media", "file"])
    }

    func testHelloRoundTripEmptyFeatures() throws {
        let m = try roundTrip(.hello(secret: "k", deviceName: "d", proto: 1, features: []))
        guard case let .hello(_, _, _, features) = m else { return XCTFail("expected hello") }
        XCTAssertTrue(features.isEmpty)
    }

    func testHelloAckRoundTrip() throws {
        let m = try roundTrip(.helloAck(accepted: true, serverName: "MacBook", features: ["clip"], dataPort: 0))
        guard case let .helloAck(accepted, name, features, port) = m else {
            return XCTFail("expected helloAck")
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(name, "MacBook")
        XCTAssertEqual(features, ["clip"])
        XCTAssertEqual(port, 0)
    }

    func testPostedRoundTrip() throws {
        let posted = WireMessage.Posted(
            key: "0|com.whatsapp|12345|null|10123",
            pkg: "com.whatsapp",
            app: "WhatsApp",
            title: "Ali",
            text: "Hey, are you around?",
            subText: nil,
            appIcon: "iVBORw0KGgo=",
            largeIcon: nil,
            picture: nil,
            postTime: 1_710_000_000_000,
            silent: false,
            actions: [
                ActionDescriptor(id: "0", title: "Reply", isReply: true),
                ActionDescriptor(id: "1", title: "Mark as read", isReply: false),
            ]
        )
        let m = try roundTrip(.posted(posted))
        guard case let .posted(p) = m else { return XCTFail("expected posted") }
        XCTAssertEqual(p.key, "0|com.whatsapp|12345|null|10123")
        XCTAssertEqual(p.pkg, "com.whatsapp")
        XCTAssertEqual(p.app, "WhatsApp")
        XCTAssertEqual(p.title, "Ali")
        XCTAssertEqual(p.text, "Hey, are you around?")
        XCTAssertNil(p.subText)
        XCTAssertEqual(p.appIcon, "iVBORw0KGgo=")
        XCTAssertNil(p.largeIcon)
        XCTAssertEqual(p.actions.count, 2)
        XCTAssertEqual(p.actions[0].title, "Reply")
        XCTAssertTrue(p.actions[0].isReply)
        XCTAssertEqual(p.actions[1].id, "1")
    }

    func testRemovedAndDismissRoundTrip() throws {
        guard case .removed = try roundTrip(.removed(key: "key1")) else {
            return XCTFail("expected removed")
        }
        guard case .dismiss = try roundTrip(.dismiss(key: "key2")) else {
            return XCTFail("expected dismiss")
        }
    }

    func testActionRoundTrip() throws {
        let withText = try roundTrip(.action(key: "k", actionId: "0", text: "hello"))
        guard case let .action(_, _, text) = withText else { return XCTFail("expected action") }
        XCTAssertEqual(text, "hello")

        let withoutText = try roundTrip(.action(key: "k", actionId: "0", text: nil))
        guard case let .action(_, _, text2) = withoutText else { return XCTFail("expected action") }
        XCTAssertNil(text2)
    }

    func testClipRoundTrip() throws {
        let m = try roundTrip(.clip(text: "hello world", origin: "mac", seq: 42))
        guard case let .clip(text, origin, seq) = m else { return XCTFail("expected clip") }
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(origin, "mac")
        XCTAssertEqual(seq, 42)
    }

    func testMediaStateRoundTrip() throws {
        let state = WireMessage.MediaState(
            pkg: "com.spotify.music", app: "Spotify", title: "Midnight City",
            artist: "M83", album: "Hurry Up", artwork: nil,
            playing: true, positionMs: 73_400, durationMs: 241_000,
            canPause: true, canSkipNext: true, canSkipPrev: false,
            volume: 6, maxVolume: 15, updatedAt: 1_710_000_000_000
        )
        let m = try roundTrip(.mediaState(state))
        guard case let .mediaState(decoded) = m else { return XCTFail("expected mediaState") }
        XCTAssertEqual(decoded.pkg, "com.spotify.music")
        XCTAssertEqual(decoded.title, "Midnight City")
        XCTAssertTrue(decoded.playing)
        XCTAssertEqual(decoded.positionMs, 73_400)
        XCTAssertEqual(decoded.volume, 6)
        XCTAssertEqual(decoded.maxVolume, 15)
    }

    func testMediaCmdRoundTrip() throws {
        let m = try roundTrip(.mediaCmd(cmd: "vol_set", value: 8))
        guard case let .mediaCmd(cmd, value) = m else { return XCTFail("expected mediaCmd") }
        XCTAssertEqual(cmd, "vol_set")
        XCTAssertEqual(value, 8)
    }

    func testBatteryStateRoundTrip() throws {
        let state = WireMessage.BatteryState(
            level: 87, charging: true, status: "charging", plugged: "ac",
            temperatureC: 32.5, voltageMv: 4250, low: false, updatedAt: 1_710_000_000_000
        )
        let m = try roundTrip(.batteryState(state))
        guard case let .batteryState(b) = m else { return XCTFail("expected batteryState") }
        XCTAssertEqual(b.level, 87)
        XCTAssertTrue(b.charging)
        XCTAssertEqual(b.status, "charging")
        XCTAssertEqual(b.temperatureC ?? 0, 32.5, accuracy: 0.001)
        XCTAssertEqual(b.voltageMv, 4250)
    }

    func testBatteryStateRoundTripNulls() throws {
        let state = WireMessage.BatteryState(
            level: -1, charging: false, status: "unknown", plugged: "none",
            temperatureC: nil, voltageMv: nil, low: false, updatedAt: 0
        )
        let m = try roundTrip(.batteryState(state))
        guard case let .batteryState(b) = m else { return XCTFail("expected batteryState") }
        XCTAssertNil(b.temperatureC)
        XCTAssertNil(b.voltageMv)
    }

    func testFileTransferRoundTrip() throws {
        let offer = WireMessage.FileOffer(xid: "x1", name: "photo.jpg", size: 2_847_392, mime: "image/jpeg", sha256: "abc")
        guard case .fileOffer = try roundTrip(.fileOffer(offer)) else { return XCTFail("expected fileOffer") }
        guard case .fileAccept = try roundTrip(.fileAccept(xid: "x1")) else { return XCTFail("expected fileAccept") }
        guard case .fileReject = try roundTrip(.fileReject(xid: "x1", reason: "too_big")) else { return XCTFail("expected fileReject") }
        guard case .fileChunk = try roundTrip(.fileChunk(xid: "x1", offset: 0, data: "aGVsbG8=", last: false)) else { return XCTFail("expected fileChunk") }
        guard case .fileDone = try roundTrip(.fileDone(xid: "x1")) else { return XCTFail("expected fileDone") }
        guard case .fileAck = try roundTrip(.fileAck(xid: "x1", ok: true, error: nil)) else { return XCTFail("expected fileAck") }
        guard case .fileCancel = try roundTrip(.fileCancel(xid: "x1", reason: "user_cancelled")) else { return XCTFail("expected fileCancel") }
    }

    func testFsBrowseRoundTrip() throws {
        guard case .fsList = try roundTrip(.fsList(reqId: "r1", path: "/sdcard")) else { return XCTFail("expected fsList") }

        let entries = [
            WireMessage.FsEntry(name: "Camera", kind: .dir, size: 0, mtime: 1_714_074_123),
            WireMessage.FsEntry(name: "IMG_0001.jpg", kind: .file, size: 2_456_123, mtime: 1_714_074_124),
        ]
        let result = try roundTrip(.fsListResult(reqId: "r1", path: "/sdcard", entries: entries, error: nil))
        guard case let .fsListResult(_, _, decodedEntries, _) = result else { return XCTFail("expected fsListResult") }
        XCTAssertEqual(decodedEntries.count, 2)

        guard case .fsDelete = try roundTrip(.fsDelete(reqId: "r2", path: "/a")) else { return XCTFail("expected fsDelete") }
        guard case .fsMkdir = try roundTrip(.fsMkdir(reqId: "r3", path: "/b")) else { return XCTFail("expected fsMkdir") }
        guard case .fsRename = try roundTrip(.fsRename(reqId: "r4", from: "/a", to: "/b")) else { return XCTFail("expected fsRename") }
        guard case .fsOpResult = try roundTrip(.fsOpResult(reqId: "r2", ok: true, error: nil)) else { return XCTFail("expected fsOpResult") }
        guard case .fsDisk = try roundTrip(.fsDisk(reqId: "r5", path: "/sdcard")) else { return XCTFail("expected fsDisk") }
        guard case .fsDiskResult = try roundTrip(.fsDiskResult(reqId: "r5", free: 39_929_436_672, total: 108_736_512_000, error: nil)) else { return XCTFail("expected fsDiskResult") }
        guard case .fsDu = try roundTrip(.fsDu(reqId: "r6", path: "/sdcard")) else { return XCTFail("expected fsDu") }
        guard case .fsDuResult = try roundTrip(.fsDuResult(reqId: "r6", path: "/sdcard", totalSize: 42_949_672_960, entries: [], error: nil)) else { return XCTFail("expected fsDuResult") }
        guard case .fsRead = try roundTrip(.fsRead(reqId: "r7", path: "/a.txt")) else { return XCTFail("expected fsRead") }
        guard case .fsReadResult = try roundTrip(.fsReadResult(reqId: "r7", size: 12_345, error: nil)) else { return XCTFail("expected fsReadResult") }
        guard case .fsWrite = try roundTrip(.fsWrite(reqId: "r8", path: "/a.txt", size: 12_345)) else { return XCTFail("expected fsWrite") }
        guard case .fsWriteReady = try roundTrip(.fsWriteReady(reqId: "r8", error: nil)) else { return XCTFail("expected fsWriteReady") }
        guard case .fsChunk = try roundTrip(.fsChunk(reqId: "r8", offset: 0, data: "aGk=", last: true)) else { return XCTFail("expected fsChunk") }
        guard case .fsCancel = try roundTrip(.fsCancel(reqId: "r9", reason: "abandoned")) else { return XCTFail("expected fsCancel") }
    }

    func testTestRequestRoundTrip() throws {
        let m = try roundTrip(.testRequest(reqId: "r7"))
        guard case let .testRequest(reqId) = m else { return XCTFail("expected testRequest") }
        XCTAssertEqual(reqId, "r7")
    }

    func testPingPongAndErrorRoundTrip() throws {
        guard case .ping = try roundTrip(.ping) else { return XCTFail("expected ping") }
        guard case .pong = try roundTrip(.pong) else { return XCTFail("expected pong") }
        let m = try roundTrip(.error(code: "bad_secret", msg: "auth failed"))
        guard case let .error(code, _) = m else { return XCTFail("expected error") }
        XCTAssertEqual(code, "bad_secret")
    }

    func testUnknownTypeDecodesAsUnknown() throws {
        let data = Data(#"{"t":"future_type","v":2,"foo":1}"#.utf8)
        let m = try WireCodec.decode(data)
        guard case let .unknown(type) = m else { return XCTFail("expected unknown, got \(m)") }
        XCTAssertEqual(type, "future_type")
    }

    func testMalformedDecodeThrows() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try WireCodec.decode(data))
    }

    func testUnknownCannotBeEncoded() {
        XCTAssertThrowsError(try WireCodec.encode(.unknown("x")))
    }

    func testEveryFrameCarriesVersionField() throws {
        let messages: [WireMessage] = [
            .hello(secret: "k", deviceName: "d", proto: 2, features: []),
            .posted(WireMessage.Posted(
                key: "k", pkg: "p", app: "a", title: nil, text: nil, subText: nil,
                appIcon: nil, largeIcon: nil, picture: nil, postTime: 0, silent: false, actions: []
            )),
            .ping,
        ]
        for message in messages {
            let data = try WireCodec.encode(message)
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(
                json.contains("\"v\":\(WireCodec.protocolVersion)"),
                "frame must carry v=\(WireCodec.protocolVersion): \(json)"
            )
        }
    }
}
