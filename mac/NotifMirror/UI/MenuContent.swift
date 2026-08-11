import AppKit
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var history = NotificationHistory.shared
    @Environment(\.openWindow) private var openWindow

    @State private var pendingVolume: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            openWindowButton

            if !history.entries.isEmpty {
                Divider()
                recentNotifications
            }

            // Quick media controls only when a session is active.
            if state.isClientConnected
                && state.peerFeatures.contains("media")
                && prefs.mediaControlEnabled
                && state.media.hasSession {
                Divider()
                miniPlayer
            }

            if state.isClientConnected && state.peerFeatures.contains("clip") {
                Divider()
                clipboardToggle
            }

            if state.isClientConnected && state.peerFeatures.contains("file") {
                Divider()
                Button(action: pickAndSendFile) {
                    Label("Send file to phone…", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
            }

            Divider()

            Button {
                ScreenMirror.shared.toggle()
            } label: {
                Label(
                    state.scrcpyRunning ? "Stop screen mirror" : "Mirror screen (scrcpy)",
                    systemImage: state.scrcpyRunning ? "stop.circle" : "display"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Divider()

            quickLinks

            if let err = state.lastError {
                Text("Error: \(err)").font(.caption).foregroundStyle(.red)
            }

            Divider()

            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Label("Quit NotifMirror", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .padding(12)
        .onChange(of: state.media.volume) { _, _ in pendingVolume = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(state.isClientConnected
                          ? Color.green.opacity(0.22)
                          : Color.secondary.opacity(0.18))
                Image(systemName: state.isClientConnected ? "bell.badge.fill" : "bell")
                    .foregroundStyle(state.isClientConnected ? .green : .secondary)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.isClientConnected
                     ? (state.pairedDeviceName ?? "Connected")
                     : "Waiting for phone…")
                    .font(.headline)
                    .lineLimit(1)
                Text("Port \(state.listenerPort == 0 ? "—" : String(state.listenerPort)) • \(state.notificationsMirroredCount) mirrored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            if state.isClientConnected,
               state.peerFeatures.contains("battery"),
               let battery = state.battery {
                batteryBadge(battery)
            }
        }
    }

    @ViewBuilder
    private func batteryBadge(_ b: BatterySnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: b.sfSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(b.tint)
            Text(b.hasLevel ? "\(b.level)%" : "—")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(b.tint)
        }
        .help(batteryTooltip(b))
    }

    private func batteryTooltip(_ b: BatterySnapshot) -> String {
        var parts: [String] = []
        if b.hasLevel { parts.append("\(b.level)%") }
        if b.charging { parts.append("charging") }
        if b.plugged != "none" && b.plugged != "unknown" { parts.append("via \(b.plugged)") }
        if let t = b.temperatureC { parts.append(String(format: "%.1f°C", t)) }
        return parts.isEmpty ? "Battery state unknown" : parts.joined(separator: " • ")
    }

    // MARK: - Open button

    private var openWindowButton: some View {
        Button {
            openMain(section: .overview)
        } label: {
            HStack {
                Label("Open NotifMirror", systemImage: "macwindow")
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("o")
    }

    // MARK: - Recent notifications

    private var recentNotifications: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if history.entries.count > 3 {
                    Button {
                        openMain(section: .notifications)
                    } label: {
                        Text("See all").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            ForEach(Array(history.entries.prefix(3))) { entry in
                MenuRecentRow(entry: entry) {
                    MainWindowSelection.shared.pendingNotificationKey = entry.key
                    openMain(section: .notifications)
                }
            }
        }
    }

    // MARK: - Quick links

    private var quickLinks: some View {
        VStack(alignment: .leading, spacing: 2) {
            linkRow("clock.arrow.circlepath", "Notifications", .notifications, "n")
            linkRow("folder.fill", "Phone files", .files, "f")
            linkRow("qrcode", "Pairing", .pairing, "p")
            linkRow("square.grid.3x3.square", "Mirrored apps", .apps, nil)
            linkRow("gearshape.fill", "Settings", .settings, ",")
        }
    }

    private func linkRow(_ symbol: String, _ title: String,
                         _ section: MainSection,
                         _ shortcut: KeyEquivalent?) -> some View {
        Button {
            openMain(section: section)
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .modifier(OptionalKeyboardShortcut(key: shortcut))
    }

    // MARK: - Mini player

    private var miniPlayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                artworkView

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.media.title ?? state.media.app ?? "Playing")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let artist = state.media.artist, !artist.isEmpty {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        transportButton("backward.fill", enabled: state.media.canSkipPrev) {
                            MediaController.shared.send(cmd: "prev")
                        }
                        transportButton(state.media.playing ? "pause.fill" : "play.fill", enabled: true) {
                            MediaController.shared.send(cmd: "toggle")
                        }
                        transportButton("forward.fill", enabled: state.media.canSkipNext) {
                            MediaController.shared.send(cmd: "next")
                        }
                    }
                }
            }

            if state.media.maxVolume > 0 { volumeControl }
        }
    }

    private var volumeControl: some View {
        let maxV = Double(state.media.maxVolume)
        let current = pendingVolume ?? Double(state.media.volume)
        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { current },
                    set: { pendingVolume = $0 }
                ),
                in: 0...maxV, step: 1,
                onEditingChanged: { editing in
                    if !editing, let v = pendingVolume {
                        MediaController.shared.send(cmd: "vol_set", value: Int(v.rounded()))
                    }
                }
            )
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        let size: CGFloat = 48
        if let b64 = state.media.artworkBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    private func transportButton(_ systemName: String,
                                 enabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }

    // MARK: - Clipboard toggle

    private var clipboardToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Clipboard sync", isOn: $prefs.clipboardSyncEnabled)
                .toggleStyle(.switch)
            if let dir = state.lastClipDirection, let at = state.lastClipAt {
                Text("\(dir == .incoming ? "← from phone" : "→ to phone") • \(Self.relative(at))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func openMain(section: MainSection) {
        MainWindowSelection.shared.pending = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickAndSendFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            FileTransferCenter.shared.sendFile(url: url)
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct OptionalKeyboardShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key)
        } else {
            content
        }
    }
}

private struct MenuRecentRow: View {
    let entry: NotificationHistory.Entry
    let onOpen: () -> Void
    @State private var copied = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.app).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.receivedAt,
                             format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(primaryText)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let code = entry.extractedCode {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(code, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                Text(copied ? "Copied" : code)
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 1)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var primaryText: String {
        if !entry.title.isEmpty && !entry.body.isEmpty {
            return "\(entry.title) — \(entry.body)"
        }
        return entry.title.isEmpty ? entry.body : entry.title
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
        }
    }
}
