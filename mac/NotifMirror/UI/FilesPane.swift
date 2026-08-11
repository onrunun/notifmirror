import AppKit
import QuickLook
import SwiftUI

// MARK: - Favorite sidebar locations

struct FavoriteLocation: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let symbol: String
}

private let defaultFavorites: [FavoriteLocation] = [
    .init(id: "sdcard",    name: "Internal Storage", path: "/sdcard",                 symbol: "externaldrive.fill"),
    .init(id: "dcim",      name: "Camera",           path: "/sdcard/DCIM/Camera",     symbol: "camera.fill"),
    .init(id: "download",  name: "Downloads",        path: "/sdcard/Download",        symbol: "arrow.down.circle.fill"),
    .init(id: "pictures",  name: "Pictures",         path: "/sdcard/Pictures",        symbol: "photo.on.rectangle"),
    .init(id: "movies",    name: "Movies",           path: "/sdcard/Movies",          symbol: "film.fill"),
    .init(id: "music",     name: "Music",            path: "/sdcard/Music",           symbol: "music.note"),
    .init(id: "documents", name: "Documents",        path: "/sdcard/Documents",       symbol: "doc.fill"),
]

// MARK: - View model

@MainActor
final class FilesModel: ObservableObject {
    @Published var devices: [AdbDevice] = []
    @Published var selectedSerial: String? = nil
    @Published var currentPath: String = "/sdcard"
    @Published var entries: [AdbEntry] = []
    @Published var selection: Set<String> = []
    @Published var isLoading: Bool = false
    @Published var busyMessage: String? = nil
    @Published var busyProgress: Double? = nil    // 0...1, or nil for indeterminate
    @Published var errorMessage: String? = nil
    @Published var freeBytes: Int64? = nil
    @Published var totalBytes: Int64? = nil

    /// Recursive folder sizes for the current listing, keyed by entry name.
    /// Populated lazily after `load()` finishes — a folder shows "—" until
    /// its `du` result lands here. Cleared on every navigation. The didSet
    /// re-applies the sort so the Size column reorders folders once sizes
    /// land, instead of staying in whatever order they had when the value
    /// was still 0.
    @Published var folderSizes: [String: Int64] = [:] {
        didSet { applySort() }
    }
    @Published var calculatingFolderSizes: Bool = false

    /// User opts to prefer adb over Wi-Fi when both are available. Persisted.
    @Published var preferAdb: Bool = UserDefaults.standard.bool(forKey: "filesPreferAdb") {
        didSet {
            UserDefaults.standard.set(preferAdb, forKey: "filesPreferAdb")
            Task { await load() }
        }
    }

    @Published var sortOrder: [KeyPathComparator<AdbEntry>] = [
        KeyPathComparator(\.mtime, order: .reverse)
    ] {
        didSet { applySort() }
    }

    // Back/Forward history (paths, browser-style).
    private var history: [String] = ["/sdcard"]
    private var historyIndex: Int = 0

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var canGoUp: Bool { currentPath != "/" }

    var selectedEntries: [AdbEntry] {
        entries.filter { selection.contains($0.id) }
    }
    var primarySelectedEntry: AdbEntry? { selectedEntries.first }

    // MARK: - Backend selection

    /// `fsbrowse` means the paired phone can serve filesystem ops over the
    /// existing WebSocket — preferred by default because it needs zero extra
    /// setup from the user. Falls back to adb (device picker, wireless
    /// debugging, etc.) otherwise, OR if the user has flipped `preferAdb` and
    /// an adb device is actually available.
    var fsbrowseAvailable: Bool {
        AppState.shared.peerFeatures.contains("fsbrowse") &&
        AppState.shared.isClientConnected
    }

    var isProtocolMode: Bool {
        guard fsbrowseAvailable else { return false }
        if preferAdb, !devices.isEmpty { return false }
        return true
    }

    private var backend: FileBackend? {
        if isProtocolMode { return ProtocolFileBackend() }
        if let serial = selectedSerial { return AdbFileBackend(serial: serial) }
        return nil
    }

    var canBrowse: Bool { backend != nil }

    /// Snapshot used by the Storage Analyzer sheet so it can keep scanning
    /// even if the user later flips Wi-Fi ↔ adb mid-session.
    func currentBackendSnapshot() -> (FileBackend, StorageAnalyzerModel.BackendKind)? {
        guard let backend else { return nil }
        return (backend, isProtocolMode ? .wifi : .adb)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        await refreshDevices(tryAutoConnect: true)
        if canBrowse {
            await load()
        }
    }

    func refreshDevices(tryAutoConnect: Bool = false) async {
        errorMessage = nil
        if tryAutoConnect, let host = AppState.shared.peerHost {
            await AdbClient.connectWireless(host: host)
        }
        do {
            let list = try await AdbClient.listDevices()
            self.devices = list
            if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = list.first?.serial
            }
        } catch {
            // Only surface adb errors when the user actually needs adb — i.e.
            // Wi-Fi isn't available, or they've explicitly opted into adb.
            if !fsbrowseAvailable || preferAdb {
                errorMessage = Self.describe(error)
            }
            self.devices = []
        }
    }

    func load() async {
        guard let backend else { return }
        let requestedPath = currentPath
        isLoading = true
        errorMessage = nil
        entries = []
        defer { isLoading = false }

        // Lazy-load callback: the adb backend streams rows as adb's stdout
        // arrives, so `.thumbnails` with thousands of files starts
        // populating the Table in ~200ms instead of waiting 2+s for the
        // whole listing. Each hop onto the main actor appends one batch.
        let onBatch: @Sendable ([AdbEntry]) -> Void = { [weak self] batch in
            Task { @MainActor in
                guard let self else { return }
                // Bail out if the user navigated away while rows were in
                // flight — the new folder's load() has already cleared
                // entries, and we'd otherwise bleed the old folder's
                // contents into it.
                guard requestedPath == self.currentPath else { return }
                self.entries.append(contentsOf: batch)
                self.applySort()
            }
        }

        do {
            let list = try await backend.list(path: requestedPath, onBatch: onBatch)
            // User may have navigated elsewhere while we were waiting; only
            // apply the result if it still matches the folder on screen.
            guard requestedPath == currentPath else { return }
            // Non-streaming backends (Wi-Fi/fsbrowse) return the whole list
            // at once without invoking onBatch — replace entries wholesale.
            // Streaming backends already populated via onBatch; re-assign
            // only if counts diverge (safety net).
            if self.entries.count != list.count {
                self.entries = list
                applySort()
            }
            selection = []
        } catch {
            guard requestedPath == currentPath else { return }
            entries = []
            errorMessage = Self.describe(error)
        }
        if requestedPath == currentPath {
            await refreshDiskUsage()
            // Fire-and-forget: folder size scan can take 10–30s on /sdcard.
            // Listing stays usable; sizes pop in as the scan finishes.
            Task { await self.calculateFolderSizes(for: requestedPath) }
        }
    }

    /// Recursive `du`-style scan of `path`'s immediate children. Populates
    /// `folderSizes` so the Size column can replace "—" with real numbers.
    /// Skips silently if the user has navigated away mid-scan.
    private func calculateFolderSizes(for path: String) async {
        guard let backend else { return }
        guard path == currentPath else { return }
        calculatingFolderSizes = true
        defer {
            if path == currentPath { calculatingFolderSizes = false }
        }
        do {
            let report = try await backend.diskAnalyze(path: path)
            guard path == currentPath else { return }
            var sizes: [String: Int64] = [:]
            for e in report.entries where e.kind == .dir {
                sizes[e.name] = e.totalSize
            }
            folderSizes = sizes
        } catch {
            // Non-fatal — folders just keep showing "—". Don't surface as a
            // listing error since the directory itself loaded fine.
        }
    }

    private func refreshDiskUsage() async {
        guard let backend else {
            freeBytes = nil; totalBytes = nil
            return
        }
        if let usage = try? await backend.diskUsage(path: currentPath) {
            freeBytes = usage.free
            totalBytes = usage.total
        }
    }

    func applySort() {
        entries.sort { a, b in
            // Directories always float to the top, regardless of column.
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in sortOrder {
                // Sorting by the Size column: folders don't have a real
                // `.size` (always 0), so KeyPathComparator on `\.size` can't
                // distinguish them. Substitute the background-computed
                // `folderSizes[name]` for directories so the column actually
                // orders folders by their recursive size once `du` finishes.
                if comparator.keyPath == \AdbEntry.size {
                    let sa = effectiveSize(a)
                    let sb = effectiveSize(b)
                    if sa != sb {
                        let ascending = comparator.order == .forward
                        return ascending ? sa < sb : sa > sb
                    }
                    continue
                }
                let result = comparator.compare(a, b)
                if result != .orderedSame {
                    return result == .orderedAscending
                }
            }
            return false
        }
    }

    private func effectiveSize(_ e: AdbEntry) -> Int64 {
        if e.isDirectory { return folderSizes[e.name] ?? 0 }
        return e.size
    }

    // MARK: - Navigation

    func navigate(into entry: AdbEntry) {
        guard entry.isDirectory || entry.kind == .symlink else { return }
        goTo(joinPath(currentPath, entry.name))
    }

    func goUp() {
        guard canGoUp else { return }
        var parent = currentPath
        if parent.hasSuffix("/") { parent.removeLast() }
        if let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
        }
        if parent.isEmpty { parent = "/" }
        goTo(parent)
    }

    func goTo(_ path: String) {
        // Trim forward history, append new entry.
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        if history.last != path { history.append(path) }
        historyIndex = history.count - 1
        currentPath = path
        clearForNavigation()
        Task { await load() }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = history[historyIndex]
        clearForNavigation()
        Task { await load() }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = history[historyIndex]
        clearForNavigation()
        Task { await load() }
    }

    /// Wipe the visible list before a navigation so the user can't keep
    /// clicking stale rows (which would otherwise append to the new path:
    /// e.g., double-click on `.thumbnails` → clicking again while the slow
    /// listing is in flight produced `.thumbnails/.thumbnails`).
    private func clearForNavigation() {
        entries = []
        selection = []
        errorMessage = nil
        isLoading = true
        folderSizes = [:]
        calculatingFolderSizes = false
    }

    // MARK: - File ops

    /// Pulls `remote` into `localURL`, preferring the current backend (Wi-Fi
    /// or adb). On any failure — disconnect, watchdog timeout, transient
    /// Wi-Fi packet loss — silently retries via adb when a device is
    /// available. Wi-Fi on this user's link is intermittently packet-lossy;
    /// adb-over-USB isn't, so this is the cheap reliability knob. The user
    /// sees "Downloading X…" succeed instead of a mysterious error.
    private func pullWithFallback(
        remote: String,
        to localURL: URL,
        entryName: String
    ) async throws {
        guard let backend else {
            throw ProtocolFileClient.FsError(message: "No backend available")
        }

        let progress: (@Sendable (Double) -> Void) = { pct in
            Task { @MainActor in self.busyProgress = pct }
        }

        // Try whichever backend is currently active.
        do {
            try await backend.pull(remote: remote, to: localURL,
                                   onProgress: progress)
            return
        } catch {
            // If we were on Wi-Fi (protocol) mode and adb is available, fall
            // back transparently. The UI already shows "Downloading…"; swap
            // the subtitle so the user knows we rerouted.
            let serial = selectedSerial
            let hadAdbDevice = !devices.isEmpty && serial != nil
            DebugLog.line("[fspull] fallback? protocolMode=\(isProtocolMode) devices=\(devices.count) selectedSerial=\(serial ?? "nil") err=\(error)")
            guard isProtocolMode, hadAdbDevice, let serial else {
                // Try to refresh adb one last time in case it just wasn't
                // discovered yet — common when the user has a device wired
                // up but bootstrap ran before adb listed it.
                DebugLog.line("[fspull] fallback rescue: refreshing adb devices")
                await refreshDevices(tryAutoConnect: true)
                if !devices.isEmpty, let rescuedSerial = selectedSerial {
                    DebugLog.line("[fspull] fallback after rescue → adb serial=\(rescuedSerial)")
                    busyMessage = "Wi-Fi stalled — retrying over adb…"
                    busyProgress = nil
                    try? FileManager.default.removeItem(at: localURL)
                    try await AdbFileBackend(serial: rescuedSerial).pull(
                        remote: remote, to: localURL, onProgress: progress
                    )
                    return
                }
                throw error
            }
            DebugLog.line("[fspull] fallback → adb serial=\(serial)")
            busyMessage = "Wi-Fi stalled — retrying over adb…"
            busyProgress = nil
            try? FileManager.default.removeItem(at: localURL)
            try await AdbFileBackend(serial: serial).pull(
                remote: remote, to: localURL,
                onProgress: progress
            )
            DebugLog.line("[fspull] fallback done")
        }
    }

    func pull(_ entry: AdbEntry, to destination: URL) async {
        guard backend != nil else { return }
        let remote = joinPath(currentPath, entry.name)
        await withBusy("Downloading \(entry.name)…") {
            try await self.pullWithFallback(
                remote: remote, to: destination, entryName: entry.name
            )
        }
    }

    /// Pull into a per-session temp dir and open with the macOS default app.
    /// Re-uses the cached copy if size + mtime still match.
    func openInDefaultApp(_ entry: AdbEntry) async {
        guard let url = await cachedLocalURL(for: entry) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Returns a local URL for the entry, pulling it into a cache dir if
    /// needed. Used for Quick Look and for promise-based drag-out.
    func cachedLocalURL(for entry: AdbEntry) async -> URL? {
        guard backend != nil, entry.kind == .file else { return nil }
        let cacheDir = Self.previewCacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let localURL = cacheDir.appendingPathComponent(entry.name)
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
           let localSize = attrs[.size] as? Int64,
           localSize == entry.size,
           let localMTime = attrs[.modificationDate] as? Date,
           localMTime >= entry.mtime {
            return localURL
        }

        try? fm.removeItem(at: localURL)
        let remote = joinPath(currentPath, entry.name)
        var ok = false
        await withBusy("Downloading \(entry.name)…") {
            try await self.pullWithFallback(
                remote: remote, to: localURL, entryName: entry.name
            )
            ok = true
        }
        return (ok && fm.fileExists(atPath: localURL.path)) ? localURL : nil
    }

    private static let previewCacheDir: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifMirror-preview", isDirectory: true)
    }()

    func push(_ localURL: URL) async {
        guard let backend else { return }
        // Protocol mode needs a full destination path; adb push accepts a dir.
        let remotePath = isProtocolMode
            ? joinPath(currentPath, localURL.lastPathComponent)
            : currentPath
        await withBusy("Uploading \(localURL.lastPathComponent)…") {
            try await backend.push(
                local: localURL,
                to: remotePath,
                onProgress: { pct in
                    Task { @MainActor in self.busyProgress = pct }
                }
            )
        }
        await load()
    }

    func delete(_ entry: AdbEntry) async {
        guard let backend else { return }
        await withBusy("Deleting \(entry.name)…") {
            try await backend.delete(path: self.joinPath(self.currentPath, entry.name))
        }
        await load()
    }

    func deleteMany(_ entries: [AdbEntry]) async {
        guard !entries.isEmpty else { return }
        for e in entries { await delete(e) }
    }

    func mkdir(_ name: String) async {
        guard let backend else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        await withBusy("Creating folder…") {
            try await backend.mkdir(path: self.joinPath(self.currentPath, cleaned))
        }
        await load()
    }

    /// Rename `entry` (in the current folder) to `newName`. No-op if the name
    /// is unchanged or empty. On success the listing reloads and the renamed
    /// entry is reselected under its new name.
    func rename(_ entry: AdbEntry, to newName: String) async {
        guard let backend else { return }
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != entry.name else { return }
        // Reject path separators — we only rename within the same folder.
        if cleaned.contains("/") {
            errorMessage = "Name cannot contain “/”"
            return
        }
        let from = joinPath(currentPath, entry.name)
        let to = joinPath(currentPath, cleaned)
        await withBusy("Renaming \(entry.name)…") {
            try await backend.rename(from: from, to: to)
        }
        await load()
        if errorMessage == nil {
            selection = [cleaned]
        }
    }

    // MARK: - Helpers

    private func withBusy(_ message: String, _ work: () async throws -> Void) async {
        busyMessage = message
        busyProgress = nil
        errorMessage = nil
        defer {
            busyMessage = nil
            busyProgress = nil
        }
        do {
            try await work()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    fileprivate func joinPath(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        return "\(base)/\(name)"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    var pathComponents: [(String, String)] {
        var acc: [(String, String)] = [("/", "/")]
        var running = ""
        for part in currentPath.split(separator: "/") {
            running += "/\(part)"
            acc.append((String(part), running))
        }
        return acc
    }

    /// Called when the user clicks a favorite. Only navigates if a backend
    /// is available; no-op otherwise so the click doesn't silently fail.
    func openFavorite(_ fav: FavoriteLocation) {
        guard canBrowse else { return }
        goTo(fav.path)
    }
}

// MARK: - Pane

struct FilesPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = FilesModel()
    @State private var newFolderSheet = false
    @State private var newFolderName = ""
    @State private var renameTarget: AdbEntry? = nil
    @State private var renameName: String = ""
    @State private var previewURL: URL? = nil
    @State private var storageSheet = false
    @FocusState private var tableFocused: Bool

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            content
                .frame(minWidth: 460)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.bootstrap() }
        .sheet(isPresented: $newFolderSheet) { newFolderSheetBody }
        .sheet(item: $renameTarget) { entry in renameSheetBody(entry) }
        .sheet(isPresented: $storageSheet) {
            if let (backend, kind) = model.currentBackendSnapshot() {
                StorageAnalyzerView(
                    rootPath: model.currentPath,
                    backend: backend,
                    backendKind: kind
                ) { parent, name in
                    model.goTo(parent)
                    model.selection = [name]
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    devicesSection
                    favoritesSection
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Phone Files").font(.headline)
                Text(currentDeviceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var currentDeviceLabel: String {
        if model.isProtocolMode {
            return state.pairedDeviceName ?? "Paired phone"
        }
        if let s = model.selectedSerial,
           let d = model.devices.first(where: { $0.serial == s }) {
            return d.model ?? d.serial
        }
        return model.devices.isEmpty ? "No device" : "Select a device"
    }

    @ViewBuilder
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isProtocolMode {
                sectionHeader("Connected via")
                HStack(spacing: 6) {
                    Image(systemName: "wifi").foregroundStyle(.green)
                    Text("Wi-Fi (\(state.pairedDeviceName ?? "phone"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)

                if !model.devices.isEmpty {
                    Toggle(isOn: $model.preferAdb) {
                        Text("Use adb instead")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                } else {
                    Text("Tip: adb is also supported (USB or wireless debugging) — typically faster and unrestricted by \"All files\" scope.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }
            } else {
                sectionHeader("Device (adb)")
                if model.devices.isEmpty {
                    Text("Connect via USB, enable wireless debugging, or grant \"All files\" on your phone to browse over Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                } else {
                    Picker("", selection: Binding(
                        get: { model.selectedSerial ?? "" },
                        set: { v in
                            model.selectedSerial = v.isEmpty ? nil : v
                            Task { await model.load() }
                        }
                    )) {
                        ForEach(model.devices) { d in
                            Text(d.label).tag(d.serial)
                        }
                    }
                    .labelsHidden()
                    .padding(.horizontal, 6)
                }

                Button {
                    Task { await model.refreshDevices(tryAutoConnect: true) }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)

                if model.fsbrowseAvailable {
                    Toggle(isOn: $model.preferAdb) {
                        Text("Prefer adb over Wi-Fi")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Favorites")
            ForEach(defaultFavorites) { fav in
                sidebarRow(fav)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    private func sidebarRow(_ fav: FavoriteLocation) -> some View {
        let active = model.currentPath == fav.path
        return HStack(spacing: 8) {
            Image(systemName: fav.symbol)
                .foregroundStyle(active ? Color.white : Color.accentColor)
                .frame(width: 18)
            Text(fav.name)
                .foregroundStyle(active ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.openFavorite(fav) }
        .opacity(model.canBrowse ? 1 : 0.45)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            toolbar
                .padding(.horizontal, 20).padding(.vertical, 8)
            breadcrumb
                .padding(.horizontal, 20).padding(.bottom, 6)
            Divider()

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            busyBar
            Divider()
            statusBar
        }
        // Invisible keyboard-shortcut buttons. We use these instead of
        // `.onKeyPress` so shortcuts fire even when the Table has focus.
        .background(keyboardShortcuts)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Phone Files").font(.largeTitle.weight(.semibold))
            Text(model.isProtocolMode
                 ? "Browse and transfer files over Wi-Fi."
                 : "Browse and transfer files over adb.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back (⌘[)")
            .disabled(!model.canGoBack)

            Button { model.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .help("Forward (⌘])")
            .disabled(!model.canGoForward)

            Button { model.goUp() } label: {
                Image(systemName: "chevron.up")
            }
            .help("Parent folder (⌘↑)")
            .disabled(!model.canGoUp || !model.canBrowse)

            Button { Task { await model.load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload (⌘R)")
            .disabled(!model.canBrowse)

            Spacer()

            Button {
                storageSheet = true
            } label: {
                Label("Storage", systemImage: "chart.pie")
            }
            .help("Find what's eating space on the phone")
            .disabled(!model.canBrowse)

            Button {
                newFolderName = ""
                newFolderSheet = true
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.canBrowse)

            Button {
                pickAndUpload()
            } label: {
                Label("Upload…", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canBrowse)
        }
    }

    // Invisible buttons carry all the keyboard shortcuts.
    @ViewBuilder
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command).disabled(!model.canGoBack)
            Button("") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command).disabled(!model.canGoForward)
            Button("") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command).disabled(!model.canGoUp)
            Button("") { Task { await model.load() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { triggerQuickLook() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { openSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { confirmDeleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { confirmDeleteSelection() }
                .keyboardShortcut(.delete, modifiers: .shift)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { idx, part in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.goTo(part.1)
                    } label: {
                        Text(idx == 0 ? "Phone" : part.0)
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(idx == model.pathComponents.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: Main table / empty states

    @ViewBuilder
    private var contentBody: some View {
        if !model.canBrowse {
            noDevice
        } else if model.isLoading && model.entries.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.errorMessage, model.entries.isEmpty {
            errorView(err)
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("Drop files here to upload, or use the Upload button.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls: urls)
                return true
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(model.entries,
              selection: $model.selection,
              sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                nameCell(entry)
            }
            .width(min: 180, ideal: 340)

            TableColumn("Size", value: \.size) { entry in
                Text(sizeText(for: entry))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            .width(min: 70, ideal: 90, max: 130)

            TableColumn("Date Modified", value: \.mtime) { entry in
                Text(Self.dateFormatter.string(from: entry.mtime))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .width(min: 120, ideal: 160, max: 220)
        }
        .focused($tableFocused)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            primaryAction(for: ids)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
            return true
        }
    }

    /// Size column text. Files use the size from `list()`. Folders show "—"
    /// until the background `du` scan reports back, then the recursive total
    /// (or "0 B" for an actually-empty folder).
    private func sizeText(for entry: AdbEntry) -> String {
        if !entry.isDirectory {
            return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        if let bytes = model.folderSizes[entry.name] {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return model.calculatingFolderSizes ? "…" : "—"
    }

    private func nameCell(_ entry: AdbEntry) -> some View {
        // No .onDrag / .draggable here: on macOS SwiftUI Tables, a per-row
        // drag gesture competes with the Table's click/double-click handling
        // — a few pixels of cursor motion flips a click into a drag and the
        // row action never fires. Use the row context menu ("Save to Mac…")
        // to pull a file out instead.
        HStack(spacing: 8) {
            Image(systemName: iconName(for: entry))
                .foregroundStyle(iconColor(for: entry))
                .frame(width: 18)
            Text(entry.name).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
            if ids.count == 1 {
                Button("Open") { openEntry(entry) }
                if entry.kind == .file {
                    Button("Quick Look") {
                        Task { await previewEntry(entry) }
                    }
                    Button("Save to Mac…") { savePull(entry) }
                }
                Button("Rename…") { startRename(entry) }
                Divider()
                Button(role: .destructive) {
                    confirmDeleteSelection()
                } label: {
                    Text("Delete")
                }
            } else {
                Button(role: .destructive) {
                    confirmDeleteSelection()
                } label: {
                    Text("Delete \(ids.count) items")
                }
            }
        }
    }

    private func primaryAction(for ids: Set<String>) {
        if let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) {
            openEntry(entry)
        }
    }

    // MARK: Empty / error states

    private var noDevice: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Android device detected")
                .font(.title3.weight(.semibold))
            Text("Connect via USB, or enable wireless debugging on your phone and start the screen mirror once — that leaves adb connected over Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button {
                Task { await model.refreshDevices(tryAutoConnect: true) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Retry") { Task { await model.load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Busy + status bars

    @ViewBuilder
    private var busyBar: some View {
        if let msg = model.busyMessage {
            Divider()
            HStack(spacing: 10) {
                if let pct = model.busyProgress {
                    ProgressView(value: pct).frame(width: 140)
                    Text("\(Int(pct * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(msg).font(.callout).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(itemCountString)
                .font(.caption).foregroundStyle(.secondary)
            if let err = model.errorMessage, !model.entries.isEmpty {
                Text("·").foregroundStyle(.tertiary).font(.caption)
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Text(diskString)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var itemCountString: String {
        let n = model.entries.count
        let sel = model.selection.count
        if sel > 0 {
            return "\(n) items, \(sel) selected"
        }
        return "\(n) items"
    }

    private var diskString: String {
        guard let free = model.freeBytes, let total = model.totalBytes, total > 0 else {
            return ""
        }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: free)) free of \(f.string(fromByteCount: total))"
    }

    // MARK: - Actions

    private func openEntry(_ entry: AdbEntry) {
        if entry.isDirectory || entry.kind == .symlink {
            model.navigate(into: entry)
        } else if entry.kind == .file {
            Task { await model.openInDefaultApp(entry) }
        }
    }

    private func openSelected() {
        if let e = model.primarySelectedEntry { openEntry(e) }
    }

    private func triggerQuickLook() {
        guard let entry = model.primarySelectedEntry, entry.kind == .file else { return }
        Task { await previewEntry(entry) }
    }

    private func previewEntry(_ entry: AdbEntry) async {
        let url = await model.cachedLocalURL(for: entry)
        if let url { previewURL = url }
    }

    private func savePull(_ entry: AdbEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.pull(entry, to: url) }
        }
    }

    private func startRename(_ entry: AdbEntry) {
        renameName = entry.name
        renameTarget = entry
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await model.push(url) }
            }
        }
    }

    private func confirmDeleteSelection() {
        let items = model.selectedEntries
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        if items.count == 1 {
            let e = items[0]
            alert.messageText = "Delete \(e.name)?"
            alert.informativeText = e.isDirectory
                ? "This will remove the folder and all its contents on your phone."
                : "This will remove the file from your phone."
        } else {
            alert.messageText = "Delete \(items.count) items?"
            alert.informativeText = "This will remove the selected files and folders on your phone."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.deleteMany(items) }
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(urls: [URL]) {
        guard !urls.isEmpty, model.canBrowse else { return }
        for url in urls {
            Task { await model.push(url) }
        }
    }

    // MARK: - Icons

    private func iconName(for entry: AdbEntry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink:   return "arrow.turn.up.right"
        case .file:      return fileIcon(for: entry.name)
        case .other:     return "questionmark.square"
        }
    }

    private func iconColor(for entry: AdbEntry) -> Color {
        switch entry.kind {
        case .directory: return .accentColor
        case .symlink:   return .orange
        case .file:      return .secondary
        case .other:     return .secondary
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return "photo"
        case "mp4", "mkv", "mov", "avi", "webm":
            return "film"
        case "mp3", "m4a", "flac", "wav", "opus", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "xz", "7z", "rar":
            return "archivebox"
        case "txt", "md", "log":
            return "doc.text"
        case "apk":
            return "shippingbox"
        default:
            return "doc"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - New folder sheet

    private func renameSheetBody(_ entry: AdbEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(entry.name)”")
                .font(.headline)
            TextField("New name", text: $renameName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = renameName
                    renameTarget = nil
                    Task { await model.rename(entry, to: name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    renameName.trimmingCharacters(in: .whitespaces).isEmpty
                    || renameName == entry.name
                )
            }
        }
        .padding(18)
        .frame(minWidth: 360)
    }

    private var newFolderSheetBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New folder in \(model.currentPath)")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
            HStack {
                Spacer()
                Button("Cancel") { newFolderSheet = false }
                Button("Create") {
                    let name = newFolderName
                    newFolderSheet = false
                    Task { await model.mkdir(name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
    }
}
