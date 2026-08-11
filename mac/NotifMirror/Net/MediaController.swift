import Foundation

/// Holds the latest media snapshot reported by the phone and sends transport
/// commands back. Pure glue — UI reads `AppState.shared.media`.
@MainActor
final class MediaController {
    static let shared = MediaController()

    private init() {}

    func handleRemoteState(_ m: WireMessage.MediaState) {
        AppState.shared.media = MediaSnapshot(
            pkg: m.pkg,
            app: m.app,
            title: m.title,
            artist: m.artist,
            album: m.album,
            artworkBase64: m.artwork,
            playing: m.playing,
            positionMs: m.positionMs,
            durationMs: m.durationMs,
            canPause: m.canPause,
            canSkipNext: m.canSkipNext,
            canSkipPrev: m.canSkipPrev,
            volume: m.volume,
            maxVolume: m.maxVolume,
            updatedAt: Date()
        )
    }

    func send(cmd: String, value: Int? = nil) {
        guard Preferences.shared.mediaControlEnabled else { return }
        WsServer.shared.send(.mediaCmd(cmd: cmd, value: value))
    }

    func refresh() {
        WsServer.shared.send(.mediaCmd(cmd: "refresh", value: nil))
    }

    /// Called when the peer disconnects — clear stale state so the UI doesn't
    /// look like it's still playing.
    func peerDisconnected() {
        AppState.shared.media = .empty
    }
}
