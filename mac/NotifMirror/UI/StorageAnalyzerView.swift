import AppKit
import SwiftUI

// MARK: - View model

@MainActor
final class StorageAnalyzerModel: ObservableObject {
    @Published var rootPath: String
    @Published var currentPath: String
    @Published var totalSize: Int64 = 0
    @Published var entries: [WireMessage.FsDuEntry] = []
    @Published var isScanning: Bool = false
    @Published var errorMessage: String? = nil
    @Published var lastScanDuration: TimeInterval = 0

    /// Snapshot of the backend at sheet-open time. We don't follow the
    /// FilesModel's `backend` mid-scan because flipping Wi-Fi ↔ adb while a
    /// `du` is in flight would just produce a confused result.
    let backend: FileBackend
    let backendKind: BackendKind

    enum BackendKind { case wifi, adb
        var label: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .adb:  return "adb"
            }
        }
    }

    /// Path stack for back navigation. Always contains at least `rootPath`
    /// at index 0; `currentPath` matches `stack.last`.
    private var stack: [String] = []

    init(rootPath: String, backend: FileBackend, backendKind: BackendKind) {
        self.rootPath = rootPath
        self.currentPath = rootPath
        self.stack = [rootPath]
        self.backend = backend
        self.backendKind = backendKind
    }

    var canGoBack: Bool { stack.count > 1 }

    var pathComponents: [(label: String, path: String)] {
        var acc: [(String, String)] = [("Phone", "/")]
        var running = ""
        for part in currentPath.split(separator: "/") {
            running += "/\(part)"
            acc.append((String(part), running))
        }
        return acc
    }

    func scan() async {
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        let start = Date()
        let requested = currentPath
        do {
            let report = try await backend.diskAnalyze(path: requested)
            // Guard against navigating away mid-scan.
            guard requested == currentPath else { return }
            self.totalSize = report.totalSize
            self.entries = report.entries.sorted { $0.totalSize > $1.totalSize }
            self.lastScanDuration = Date().timeIntervalSince(start)
        } catch {
            guard requested == currentPath else { return }
            self.entries = []
            self.totalSize = 0
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func enter(_ entry: WireMessage.FsDuEntry) {
        guard entry.kind == .dir else { return }
        let next = joined(currentPath, entry.name)
        stack.append(next)
        currentPath = next
        Task { await scan() }
    }

    func goBack() {
        guard canGoBack else { return }
        stack.removeLast()
        currentPath = stack.last!
        Task { await scan() }
    }

    func goTo(_ path: String) {
        guard path != currentPath else { return }
        // Treat any breadcrumb hop as a fresh stack root from `rootPath`'s
        // perspective: keep root at index 0, then path. Avoids surprising
        // back behaviour after a few drill-downs and a breadcrumb jump.
        stack = [rootPath, path].uniqueInOrder()
        currentPath = path
        Task { await scan() }
    }

    func delete(_ entry: WireMessage.FsDuEntry) async {
        let target = joined(currentPath, entry.name)
        do {
            try await backend.delete(path: target)
            // Rescan so the bars and totals reflect the deletion.
            await scan()
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Used by "Reveal in Files" — caller closes the sheet and points the
    /// FilesModel at `revealParent` with `revealName` highlighted.
    func revealInfo(for entry: WireMessage.FsDuEntry) -> (parent: String, name: String) {
        return (currentPath, entry.name)
    }

    private func joined(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

private extension Array where Element: Equatable {
    func uniqueInOrder() -> [Element] {
        var seen: [Element] = []
        for e in self where !seen.contains(e) { seen.append(e) }
        return seen
    }
}

// MARK: - View

struct StorageAnalyzerView: View {
    @StateObject private var model: StorageAnalyzerModel
    @Environment(\.dismiss) private var dismiss

    /// Closure handed in by FilesPane so "Reveal in Files" can navigate the
    /// underlying browser without us reaching into FilesModel directly.
    var onReveal: (_ parent: String, _ name: String) -> Void

    init(
        rootPath: String,
        backend: FileBackend,
        backendKind: StorageAnalyzerModel.BackendKind,
        onReveal: @escaping (String, String) -> Void
    ) {
        _model = StateObject(wrappedValue: StorageAnalyzerModel(
            rootPath: rootPath, backend: backend, backendKind: backendKind
        ))
        self.onReveal = onReveal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .task { await model.scan() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(.tint)
                Text("Storage")
                    .font(.title2.weight(.semibold))
                Text(model.backendKind.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .keyboardShortcut(.escape, modifiers: [])
            }

            HStack(spacing: 6) {
                Button { model.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canGoBack)
                .help("Back")

                Button { Task { await model.scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
                .help("Rescan")

                breadcrumb
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

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
                        model.goTo(part.path)
                    } label: {
                        Text(part.label).font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(idx == model.pathComponents.count - 1 ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var contentBody: some View {
        if model.isScanning && model.entries.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning \(model.currentPath)…")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Large folders can take 10–30 seconds.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.errorMessage, model.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(err)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Button("Retry") { Task { await model.scan() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "Folder is empty",
                systemImage: "tray",
                description: Text("Nothing to analyze in \(model.currentPath).")
            )
        } else {
            entryList
        }
    }

    private var entryList: some View {
        let maxBytes = max(1, model.entries.first?.totalSize ?? 1)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.entries) { entry in
                    StorageRow(
                        entry: entry,
                        maxBytes: maxBytes,
                        totalBytes: model.totalSize,
                        onOpen: { model.enter(entry) },
                        onReveal: {
                            let info = model.revealInfo(for: entry)
                            onReveal(info.parent, info.name)
                            dismiss()
                        },
                        onDelete: { confirmDelete(entry) }
                    )
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isScanning && !model.entries.isEmpty {
                ProgressView().controlSize(.small)
                Text("Rescanning…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(summaryString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.lastScanDuration > 0 {
                Text(String(format: "Scanned in %.1fs", model.lastScanDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var summaryString: String {
        let total = ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)
        let count = model.entries.count
        let base = "\(total) across \(count) item\(count == 1 ? "" : "s")"
        let files = model.entries.reduce(0) { $0 + $1.fileCount }
        guard files > 0 else { return base }   // adb mode doesn't report file counts
        return "\(base) · \(files) file\(files == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func confirmDelete(_ entry: WireMessage.FsDuEntry) {
        let alert = NSAlert()
        let humanSize = ByteCountFormatter.string(fromByteCount: entry.totalSize, countStyle: .file)
        alert.messageText = "Delete \(entry.name)?"
        alert.informativeText = entry.kind == .dir
            ? "This removes the folder and its contents (\(humanSize)) from your phone."
            : "This removes the file (\(humanSize)) from your phone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.delete(entry) }
        }
    }
}

// MARK: - Row

private struct StorageRow: View {
    let entry: WireMessage.FsDuEntry
    let maxBytes: Int64
    let totalBytes: Int64
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name)
                        .lineLimit(1)
                    if entry.kind == .dir, entry.fileCount > 0 {
                        // adb mode reports fileCount=0 because `du` doesn't
                        // give it cheaply — hide the badge instead of lying.
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: entry.totalSize, countStyle: .file))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(percentString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 48, alignment: .trailing)
                }
                bar
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(hovering ? Color.gray.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .contextMenu {
            if entry.kind == .dir {
                Button("Open") { onOpen() }
            }
            Button("Reveal in Files") { onReveal() }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let frac = maxBytes > 0
                ? CGFloat(entry.totalSize) / CGFloat(maxBytes)
                : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(barColor)
                    .frame(width: max(2, geo.size.width * frac))
            }
        }
        .frame(height: 6)
    }

    private var percentString: String {
        guard totalBytes > 0 else { return "" }
        let pct = Double(entry.totalSize) / Double(totalBytes) * 100
        if pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }

    private var iconName: String {
        switch entry.kind {
        case .dir:   return "folder.fill"
        case .link:  return "arrow.turn.up.right"
        case .file:  return "doc"
        case .other: return "questionmark.square"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .dir:  return .accentColor
        case .link: return .orange
        default:    return .secondary
        }
    }

    /// Visual heat: bigger entries get a bolder colour so the eye can pick
    /// out the offenders without reading the percentages.
    private var barColor: Color {
        guard totalBytes > 0 else { return .accentColor }
        let pct = Double(entry.totalSize) / Double(totalBytes)
        switch pct {
        case 0.5...:   return .red
        case 0.25...:  return .orange
        case 0.10...:  return .yellow
        default:       return .accentColor
        }
    }
}
