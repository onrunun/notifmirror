@testable import NotifMirror
import XCTest

/// The pairing QR payload shape is a cross-platform contract (Android parses
/// it to connect). Lock the JSON shape down so the wire format can't drift.
final class PairingPayloadTests: XCTestCase {

    func testPayloadJSONShape() throws {
        let payload = PairingPayload(
            v: 3,
            host: "192.168.1.42",
            port: 53712,
            secret: "c2VjcmV0",
            name: "Test MacBook",
            fp: "ZmM5M2ZlMTg="
        )
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["v"] as? Int, 3)
        XCTAssertEqual(dict["host"] as? String, "192.168.1.42")
        XCTAssertEqual(dict["port"] as? Int, 53712)
        XCTAssertEqual(dict["secret"] as? String, "c2VjcmV0")
        XCTAssertEqual(dict["name"] as? String, "Test MacBook")
        XCTAssertEqual(dict["fp"] as? String, "ZmM5M2ZlMTg=")

        // Every key the Android client requires must be present, and only those.
        XCTAssertEqual(
            Set(dict.keys),
            Set(["v", "host", "port", "secret", "name", "fp"])
        )
        _ = json
    }
}
