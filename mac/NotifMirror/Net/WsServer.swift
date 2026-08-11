import Foundation
import Network

final class WsServer: @unchecked Sendable {
    static let shared = WsServer()

    private let queue = DispatchQueue(label: "com.notifmirror.app.wsserver")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var authedConnection: NWConnection?

    /// Features advertised by the currently-authenticated client. Empty until
    /// HELLO arrives. Read-only from outside.
    private(set) var peerFeatures: Set<String> = []

    private init() {}

    static let listenPortPrefKey = "serverListenPort"

    func start() throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 8 * 1024 * 1024 // 8 MiB cap

        // TLS with the self-signed leaf cert from SelfSignedCert. The
        // Android client pins this cert by SPKI SHA-256 (the `fp` field in
        // the pairing QR), so no CA chain is involved — we hand the same
        // identity to every connecting client and rely entirely on the
        // pinning + the pairing secret for authentication.
        let identity = try SelfSignedCert.shared.identity()
        guard let secId = sec_identity_create(identity) else {
            throw CertError.parse("sec_identity_create returned nil")
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions, secId
        )

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Kick Nagle off on the server side of the WS so inbound chunk
            // ACKs go back without waiting, and keepalive so genuinely dead
            // connections surface quickly.
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // Reuse the last successful port so the QR we handed to the phone
        // stays valid across app restarts. Falls back to an ephemeral port
        // if the saved one is taken (stateUpdateHandler handles that path).
        let savedPort = UserDefaults.standard.object(forKey: Self.listenPortPrefKey) as? Int
        let l: NWListener
        if let raw = savedPort, raw > 0, raw <= 65535,
           let nwPort = NWEndpoint.Port(rawValue: UInt16(raw)) {
            l = try NWListener(using: parameters, on: nwPort)
        } else {
            l = try NWListener(using: parameters)
        }
        l.service = NWListener.Service(name: "notifmirror", type: "_andnotif._tcp")

        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = l.port?.rawValue ?? 0
                if port > 0 {
                    UserDefaults.standard.set(Int(port), forKey: Self.listenPortPrefKey)
                }
                Task { @MainActor in
                    AppState.shared.listenerPort = port
                    AppState.shared.isServerListening = true
                    AppState.shared.lastError = nil
                }
                NSLog("WsServer listening on port \(port)")
            case .failed(let err):
                Task { @MainActor in
                    AppState.shared.isServerListening = false
                    AppState.shared.lastError = "Listener failed: \(err.localizedDescription)"
                }
                NSLog("WsServer failed: \(err)")
                // If we were trying to rebind a previously-used port that's
                // now taken by something else, drop it so the restart picks
                // an ephemeral one.
                UserDefaults.standard.removeObject(forKey: Self.listenPortPrefKey)
                self?.scheduleRestart()
            case .cancelled:
                Task { @MainActor in AppState.shared.isServerListening = false }
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.queue.async { self?.accept(conn) }
        }

        l.start(queue: queue)
        listener = l

        // DataServer (separate raw-TCP bulk channel) is retired: file bytes
        // now ride as WS binary frames on this very listener, which proved
        // much more robust than a sibling TCP socket on the same radio.
    }

    private func scheduleRestart() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            try? self?.start()
        }
    }

    private func accept(_ conn: NWConnection) {
        if let existing = connection, existing !== conn {
            NSLog("dropping previous connection in favour of new client")
            existing.cancel()
            connection = nil
            authedConnection = nil
            peerFeatures = []
            Task { @MainActor in
                AppState.shared.isClientConnected = false
                AppState.shared.pairedDeviceName = nil
            }
        }

        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                NSLog("client connection ready")
            case .failed(let err):
                NSLog("client failed: \(err)")
                self.queue.async { self.dropConnection(conn) }
            case .cancelled:
                self.queue.async { self.dropConnection(conn) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func dropConnection(_ conn: NWConnection) {
        // Only mutate session state when the connection we're dropping is
        // actually the live one. A `.cancelled` event for a stale socket
        // (e.g. the previous client that we kicked when a new one came in)
        // would otherwise spuriously flip `isClientConnected` to false even
        // though a fresh client is already authenticated — making the UI
        // flicker into "Waiting for phone…" while the phone is still talking.
        let wasCurrent = (connection === conn) || (authedConnection === conn)
        if connection === conn { connection = nil }
        if authedConnection === conn {
            authedConnection = nil
            peerFeatures = []
        }
        guard wasCurrent else {
            DebugLog.line("[ws] stale drop ignored — current session unaffected")
            return
        }
        Task { @MainActor in
            AppState.shared.isClientConnected = false
            AppState.shared.pairedDeviceName = nil
            AppState.shared.peerHost = nil
        }
        // Tell subsystems that rely on the client side so they can reset
        // their state (in-flight transfers etc).
        Task { @MainActor in
            FileTransferCenter.shared.peerDisconnected()
            MediaController.shared.peerDisconnected()
            ProtocolFileClient.shared.peerDisconnected()
            BatteryStore.shared.peerDisconnected()
        }
    }

    private static func extractHost(from conn: NWConnection) -> String? {
        func hostString(_ endpoint: NWEndpoint?) -> String? {
            guard case let .hostPort(host, _) = endpoint else { return nil }
            switch host {
            case .ipv4(let a):
                return a.debugDescription
            case .ipv6(let a):
                // Strip zone id if present (e.g. fe80::1%en0 → fe80::1).
                let s = a.debugDescription
                return s.split(separator: "%").first.map(String.init) ?? s
            case .name(let n, _):
                return n
            @unknown default:
                return nil
            }
        }
        return hostString(conn.currentPath?.remoteEndpoint) ?? hostString(conn.endpoint)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, context, isComplete, error in
            guard let self, let conn else { return }
            if let error {
                DebugLog.line("[ws] receive error: \(error)")
                conn.cancel()
                return
            }
            var opcode = "?"
            if let meta = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text: opcode = "text"
                case .binary: opcode = "bin"
                case .ping: opcode = "PING"
                case .pong: opcode = "PONG"
                case .close: opcode = "close"
                @unknown default: opcode = "?"
                }
            }
            DebugLog.line("[ws] recv opcode=\(opcode) len=\(data?.count ?? 0)")
            if let data, !data.isEmpty {
                self.handleIncoming(data: data, context: context, on: conn)
            }
            if conn.state != .cancelled {
                self.receive(on: conn)
            }
            _ = isComplete
        }
    }

    private func handleIncoming(data: Data, context: NWConnection.ContentContext?, on conn: NWConnection) {
        if let meta = context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
            switch meta.opcode {
            case .text:
                break
            case .binary:
                // Bulk file payloads ride as binary WS frames now, not a
                // separate raw-TCP channel. Reuses the OkHttp/NWConnection
                // socket that we already know stays healthy end-to-end
                // (WS PINGs keep flowing during long transfers, while a
                // sibling raw TCP socket stalled for 30 s at a time on
                // the same radio).
                //
                // Defense-in-depth: only honour binary frames on the
                // authenticated socket. The text-message path already
                // refuses non-HELLO traffic before HELLO completes; mirror
                // that here so an unpaired peer can't even feed bytes into
                // the FileTransferCenter / ProtocolFileClient correlation
                // tables.
                guard authedConnection === conn else {
                    DebugLog.line("[ws] dropping binary frame from unauthed conn")
                    return
                }
                handleBinaryFrame(data: data)
                return
            case .close:
                conn.cancel()
                return
            default:
                return
            }
        }

        let message: WireMessage
        do {
            message = try WireCodec.decode(data)
        } catch {
            NSLog("decode error: \(error)")
            sendError(on: conn, code: "malformed", msg: "\(error)")
            queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
            return
        }

        if authedConnection !== conn {
            switch message {
            case let .hello(secret, deviceName, proto, features):
                guard proto >= WireCodec.minAcceptedProtocol,
                      proto <= WireCodec.protocolVersion else {
                    sendError(on: conn, code: "bad_proto", msg: "unsupported proto \(proto)")
                    queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
                    return
                }
                guard Pairing.shared.verify(secret) else {
                    sendError(on: conn, code: "bad_secret", msg: "auth failed")
                    queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
                    return
                }
                authedConnection = conn
                peerFeatures = Set(features)
                let peerHost = Self.extractHost(from: conn)
                Task { @MainActor in
                    AppState.shared.isClientConnected = true
                    AppState.shared.pairedDeviceName = deviceName
                    AppState.shared.peerFeatures = Set(features)
                    AppState.shared.peerHost = peerHost
                }
                let ack = WireMessage.helloAck(
                    accepted: true,
                    serverName: Host.current().localizedName ?? "Mac",
                    features: FeatureRegistry.supported,
                    dataPort: 0  // retired; file bytes ride as WS binary frames
                )
                send(ack, on: conn)
                // Ask the phone for its current media snapshot so the
                // mini-player is populated right away.
                if peerFeatures.contains("media") {
                    send(.mediaCmd(cmd: "refresh", value: nil), on: conn)
                }
                // Push our muted-app snapshot so the two sides converge on
                // (re)connect. The phone does the same from its side.
                Task { @MainActor in
                    WsServer.shared.send(.blocklist(packages: BlockedApps.shared.snapshot()))
                }
            default:
                sendError(on: conn, code: "bad_secret", msg: "hello required first")
                queue.asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
            }
            return
        }

        switch message {
        case .posted(let p):
            Task { @MainActor in
                AppState.shared.incrementMirrored()
                // End-to-end test correlator: if a `test_request` is in
                // flight and this `posted` carries its nonce in the body
                // (or title), clear the pending marker so the UI sees
                // "round-trip succeeded" instead of "timed out".
                if let pending = AppState.shared.pendingE2ETestReqId,
                   ((p.text ?? "").contains(pending) || (p.title ?? "").contains(pending)) {
                    AppState.shared.pendingE2ETestReqId = nil
                }
                NotificationPresenter.shared.handlePosted(p)
            }
        case .removed(let key):
            Task { @MainActor in
                NotificationPresenter.shared.handleRemoved(key: key)
            }
        case let .clip(text, origin, seq):
            Task { @MainActor in
                ClipboardSync.shared.handleRemoteClip(text: text, origin: origin, seq: seq)
            }
        case .mediaState(let m):
            Task { @MainActor in
                MediaController.shared.handleRemoteState(m)
            }
        case .batteryState(let b):
            Task { @MainActor in
                BatteryStore.shared.handleRemoteState(b)
            }
        case .blocklist(let packages):
            Task { @MainActor in
                BlockedApps.shared.applyRemote(packages)
            }
        case let .fileOffer(offer):
            Task { @MainActor in
                FileTransferCenter.shared.handleOffer(offer)
            }
        case let .fileAccept(xid):
            Task { @MainActor in FileTransferCenter.shared.handleAccept(xid: xid) }
        case let .fileReject(xid, reason):
            Task { @MainActor in FileTransferCenter.shared.handleReject(xid: xid, reason: reason) }
        case let .fileChunk(xid, offset, data, last):
            // Legacy WS chunk path — bytes now flow through the raw-TCP data
            // channel. Kept here as a fallback for older peers that haven't
            // picked up a dataPort yet; decode the base64 and hand off to the
            // same binary handler.
            Task { @MainActor in
                let bytes = Data(base64Encoded: data) ?? Data()
                FileTransferCenter.shared.handleBinaryChunk(
                    xid: xid, offset: offset, bytes: bytes, last: last
                )
            }
        case let .fileDone(xid):
            Task { @MainActor in FileTransferCenter.shared.handleDone(xid: xid) }
        case let .fileAck(xid, ok, err):
            Task { @MainActor in FileTransferCenter.shared.handleAck(xid: xid, ok: ok, error: err) }
        case let .fileCancel(xid, reason):
            Task { @MainActor in FileTransferCenter.shared.handleCancel(xid: xid, reason: reason) }
        case .fsListResult, .fsOpResult, .fsDiskResult, .fsDuResult,
             .fsReadResult, .fsWriteReady, .fsChunk:
            // All "phone → Mac" browse responses route through the correlation
            // table in ProtocolFileClient. `fs_chunk` going Mac → phone is only
            // sent outbound; the inbound path here is for fs_read bodies.
            Task { @MainActor in ProtocolFileClient.shared.deliver(message) }
        case .fsList, .fsDelete, .fsMkdir, .fsRename, .fsDisk, .fsDu, .fsRead, .fsWrite, .fsCancel:
            // Requests are Mac → phone only. The phone shouldn't send them;
            // drop silently rather than error-out in case a future peer mis-
            // wires directions.
            NSLog("unexpected inbound browse request")
        case .ping:
            send(.pong, on: conn)
        case .pong:
            break
        case .error(let code, let msg):
            NSLog("client error: \(code) \(msg)")
        case .unknown(let t):
            NSLog("ignoring unknown message type: \(t)")
        default:
            break
        }
    }

    func sendDismiss(key: String) {
        send(.dismiss(key: key))
    }

    func sendAction(key: String, actionId: String, text: String?) {
        send(.action(key: key, actionId: actionId, text: text))
    }

    /// Ask the phone to post a real notification from the NotifMirror app
    /// package, so the NotificationListener picks it up and round-trips it
    /// back as a normal `posted`. Caller correlates by `reqId`.
    func sendTestRequest(reqId: String) {
        send(.testRequest(reqId: reqId))
    }

    /// Generic send used by clipboard / media / file subsystems.
    func send(_ message: WireMessage) {
        queue.async { [weak self] in
            guard let self, let conn = self.authedConnection else { return }
            self.send(message, on: conn)
        }
    }

    var isClientAuthed: Bool {
        // Reads are off-queue but authedConnection is only assigned from the
        // queue. For UI purposes an occasional torn read is fine.
        authedConnection != nil
    }

    /// Cancel the listener and start a fresh one so a freshly-minted TLS
    /// identity (after the pairing secret + cert are rotated) actually takes
    /// effect — `NWProtocolTLS.Options` is bound at listener-creation time,
    /// so the running listener would otherwise keep presenting the old cert.
    func restartListener() {
        queue.async { [weak self] in
            guard let self else { return }
            let oldConn = self.connection
            self.connection = nil
            self.authedConnection = nil
            self.peerFeatures = []
            oldConn?.cancel()
            self.listener?.cancel()
            self.listener = nil
            Task { @MainActor in
                AppState.shared.isClientConnected = false
                AppState.shared.pairedDeviceName = nil
                AppState.shared.peerHost = nil
                AppState.shared.peerFeatures = []
                AppState.shared.isServerListening = false
                FileTransferCenter.shared.peerDisconnected()
                MediaController.shared.peerDisconnected()
                ProtocolFileClient.shared.peerDisconnected()
                BatteryStore.shared.peerDisconnected()
            }
            do {
                try self.start()
            } catch {
                NSLog("WsServer restart failed: \(error)")
                Task { @MainActor in
                    AppState.shared.lastError = "TLS restart failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Force-drops any live client. Used when the pairing secret is rotated —
    /// the existing connection was authenticated with the old secret, so we
    /// tear it down so the phone has to re-pair with the new QR.
    func disconnectActiveClient() {
        queue.async { [weak self] in
            guard let self else { return }
            let conn = self.connection
            self.connection = nil
            self.authedConnection = nil
            self.peerFeatures = []
            conn?.cancel()
            Task { @MainActor in
                AppState.shared.isClientConnected = false
                AppState.shared.pairedDeviceName = nil
                AppState.shared.peerHost = nil
                AppState.shared.peerFeatures = []
                FileTransferCenter.shared.peerDisconnected()
                MediaController.shared.peerDisconnected()
                ProtocolFileClient.shared.peerDisconnected()
                BatteryStore.shared.peerDisconnected()
            }
        }
    }

    // MARK: - Binary chunk framing
    //
    // Fixed 18-byte header followed by raw payload:
    //   [0]     kind  (0x01 = file_chunk, 0x02 = fs_chunk)
    //   [1..9]  id    (8 ASCII hex chars — xid / reqId)
    //   [9..17] offset (uint64, big-endian)
    //   [17]    flags (bit 0 = last)
    //   [18..]  payload
    //
    // No length field is needed because each WebSocket message is already
    // framed end-to-end; we read `data.count` once NW delivers it.

    static let chunkKindFile:      UInt8 = 0x01
    static let chunkKindFs:        UInt8 = 0x02
    /// Heartbeat from phone — tiny WS binary frame sent every ~10 ms during
    /// a bulk transfer to keep the phone's Wi-Fi radio out of power-save so
    /// AP→phone ACKs aren't buffered to DTIM boundaries. Silently dropped
    /// here — the point is just the radio keep-alive.
    static let chunkKindHeartbeat: UInt8 = 0xFE

    /// Encode + send a binary chunk frame on the authenticated connection.
    func sendBinaryChunk(
        kind: UInt8, id: String, offset: Int64, payload: Data, last: Bool
    ) {
        guard let idBytes = id.data(using: .ascii), idBytes.count == 8 else {
            NSLog("sendBinaryChunk: bad id \(id)")
            return
        }
        var buf = Data(capacity: 18 + payload.count)
        buf.append(kind)
        buf.append(idBytes)
        // Offset: 8 bytes big-endian, assembled by hand so we don't rely on
        // `withUnsafeBytes` of a misaligned storage position (Swift asserts
        // on unaligned loads in debug builds).
        let uo = UInt64(bitPattern: offset)
        for i in 0..<8 {
            buf.append(UInt8((uo >> ((7 - i) * 8)) & 0xFF))
        }
        buf.append(last ? 0x01 : 0x00)
        buf.append(payload)

        queue.async { [weak self] in
            guard let self, let conn = self.authedConnection else { return }
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(
                identifier: "bin", metadata: [meta]
            )
            conn.send(content: buf, contentContext: context, isComplete: true,
                      completion: .contentProcessed { err in
                if let err { NSLog("sendBinary err: \(err)") }
            })
        }
    }

    private func handleBinaryFrame(data: Data) {
        guard let firstByte = data.first else { return }
        if firstByte == Self.chunkKindHeartbeat { return }  // radio keep-alive
        guard data.count >= 18 else {
            NSLog("binary frame too short: \(data.count)")
            return
        }
        let base = data.startIndex
        let kind = data[base]
        let flagsByte = data[base + 17]
        guard let id = String(data: data[(base + 1)..<(base + 9)], encoding: .ascii) else {
            return
        }
        // Decode offset byte-by-byte to sidestep unaligned-load asserts.
        var offU: UInt64 = 0
        for i in 0..<8 {
            offU = (offU << 8) | UInt64(data[base + 9 + i])
        }
        let offset = Int64(bitPattern: offU)
        let last = (flagsByte & 0x01) != 0
        let payload: Data = data.count > 18
            ? data.subdata(in: (base + 18)..<data.endIndex)
            : Data()

        switch kind {
        case Self.chunkKindFile:
            Task { @MainActor in
                FileTransferCenter.shared.handleBinaryChunk(
                    xid: id, offset: offset, bytes: payload, last: last
                )
            }
        case Self.chunkKindFs:
            Task { @MainActor in
                ProtocolFileClient.shared.handleBinaryChunk(
                    reqId: id, offset: offset, bytes: payload, last: last
                )
            }
        default:
            NSLog("unknown binary frame kind: \(kind)")
        }
    }

    private func send(_ message: WireMessage, on conn: NWConnection) {
        let data: Data
        do { data = try WireCodec.encode(message) } catch {
            NSLog("encode error: \(error)"); return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: context, isComplete: true,
                  completion: .contentProcessed { err in
            if let err { NSLog("send err: \(err)") }
        })
    }

    private func sendError(on conn: NWConnection, code: String, msg: String) {
        send(.error(code: code, msg: msg), on: conn)
    }
}

enum FeatureRegistry {
    /// Features this server *supports receiving*. `fsbrowse` is advertised so
    /// the phone knows it can opt-in (the actual decision is phone-side — it
    /// only sets `fsbrowse` in its `hello.features` when MANAGE_EXTERNAL_STORAGE
    /// is granted).
    static let supported: [String] = ["clip", "media", "file", "fsbrowse"]
}
