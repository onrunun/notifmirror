import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Sidebar sections

enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case pairing
    case notifications
    case apps
    case clipboard
    case media
    case transfers
    case files
    case screen
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .pairing: return "Pairing"
        case .notifications: return "Notifications"
        case .apps: return "Mirrored Apps"
        case .clipboard: return "Clipboard"
        case .media: return "Media"
        case .transfers: return "File Transfers"
        case .files: return "Phone Files"
        case .screen: return "Screen Mirror"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "circle.grid.2x2.fill"
        case .pairing: return "qrcode"
        case .notifications: return "bell.badge.fill"
        case .apps: return "square.grid.3x3.square"
        case .clipboard: return "doc.on.clipboard.fill"
        case .media: return "music.note"
        case .transfers: return "arrow.up.arrow.down.circle.fill"
        case .files: return "folder.fill"
        case .screen: return "display"
        case .settings: return "gearshape.fill"
        }
    }
}

// Global deep-link selection used by the menu-bar popup to jump directly
// to a section when the main window opens.
@MainActor
final class MainWindowSelection: ObservableObject {
    static let shared = MainWindowSelection()
    @Published var pending: MainSection? = nil
    /// When set, the Notifications pane scrolls to and highlights this key,
    /// then clears the field. Used by the macOS notification-click handler.
    @Published var pendingNotificationKey: String? = nil
    private init() {}
}

// MARK: - Main window

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var selectionBridge = MainWindowSelection.shared
    @State private var selection: MainSection? = .overview
    @State private var isDropTarget: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .frame(minWidth: 520, minHeight: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            consumePending()
            DockIconController.shared.acquire()
        }
        .onDisappear {
            DockIconController.shared.release()
        }
        .onChange(of: selectionBridge.pending) { _, _ in consumePending() }
        .overlay {
            if isDropTarget { dropOverlay }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
    }

    private var canAcceptFiles: Bool {
        state.isClientConnected && state.peerFeatures.contains("file")
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(canAcceptFiles ? 0.18 : 0.10)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: canAcceptFiles
                      ? "paperplane.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(canAcceptFiles ? Color.accentColor : .orange)
                Text(canAcceptFiles
                     ? "Drop to send to \(state.pairedDeviceName ?? "phone")"
                     : "Connect a phone to send files")
                    .font(.title2.weight(.semibold))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(radius: 14)
            )
            .padding(40)
        }
        .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptFiles else { return false }
        var accepted = 0
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    FileTransferCenter.shared.sendFile(url: url)
                }
            }
            accepted += 1
        }
        return accepted > 0
    }

    private func consumePending() {
        if let target = selectionBridge.pending {
            selection = target
            selectionBridge.pending = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List(MainSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(sidebarBadge(section))
                    .tag(section)
            }
            .listStyle(.sidebar)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(state.isClientConnected ? Color.green.opacity(0.22) : Color.secondary.opacity(0.18))
                Image(systemName: state.isClientConnected ? "bell.badge.fill" : "bell")
                    .foregroundStyle(state.isClientConnected ? .green : .secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("NotifMirror")
                    .font(.headline)
                Text(state.isClientConnected
                     ? (state.pairedDeviceName ?? "Paired phone")
                     : "Waiting for phone…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func sidebarBadge(_ section: MainSection) -> Int {
        switch section {
        case .notifications: return state.notificationsMirroredCount
        case .transfers: return state.transfers.count
        default: return 0
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:       OverviewPane()
        case .pairing:        PairingPane()
        case .notifications:  NotificationsPane()
        case .apps:           MirroredAppsPane()
        case .clipboard:      ClipboardPane()
        case .media:          MediaPane()
        case .transfers:      TransfersPane()
        case .files:          FilesPane()
        case .screen:         ScreenMirrorPane()
        case .settings:       SettingsPane()
        }
    }
}

// MARK: - Pane chrome

private struct PaneContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Overview pane

private struct OverviewPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var history = NotificationHistory.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        PaneContainer("Overview", subtitle: subtitle) {
            ScrollView {
                VStack(spacing: 16) {
                    if state.isClientConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }

    private var subtitle: String {
        if state.isClientConnected {
            return state.pairedDeviceName.map { "Streaming from \($0)." } ?? "Streaming from your phone."
        } else if state.isServerListening {
            return "Scan the code below from NotifMirror on your Android phone."
        } else {
            return "The local server isn't running. Try relaunching NotifMirror."
        }
    }

    // MARK: Disconnected state — inline pairing QR so the user doesn't have
    // to navigate to a separate tab to recover.

    @ViewBuilder
    private var disconnectedContent: some View {
        if state.listenerPort == 0 {
            Card {
                ProgressView("Starting local server…")
                    .frame(maxWidth: .infinity).padding()
            }
        } else if let payload = Pairing.shared.payloadJSON(
            host: LocalAddress.currentLanIPv4(),
            port: Int(state.listenerPort)
        ) {
            Card {
                VStack(spacing: 14) {
                    QRCodeView(payload: payload)
                        .id(state.pairingRevision)
                        .frame(width: 220, height: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white)
                        )

                    Text("Open NotifMirror on your Android phone, tap **Pair**, and scan this code.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)

                    HStack(spacing: 16) {
                        Label(LocalAddress.currentLanIPv4(), systemImage: "network")
                        Label(String(state.listenerPort), systemImage: "number.circle")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)

                    HStack(spacing: 10) {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(payload, forType: .string)
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            _ = Pairing.shared.regenerateSecret()
                            WsServer.shared.restartListener()
                            state.pairingRevision &+= 1
                        } label: {
                            Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Connected state — focus on what's actually happening.

    @ViewBuilder
    private var connectedContent: some View {
        statusRow

        if state.media.hasSession && prefs.mediaControlEnabled {
            nowPlayingCard
        }

        let activeTransfers = state.transfers.values.filter {
            switch $0.status {
            case .active, .pending: return true
            default: return false
            }
        }
        if !activeTransfers.isEmpty {
            activeTransfersCard(items: activeTransfers.sorted { $0.name < $1.name })
        }

        recentNotificationsCard
    }

    private var statusRow: some View {
        Card {
            HStack(spacing: 12) {
                Circle().fill(.green).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.pairedDeviceName ?? "Connected")
                        .font(.headline)
                    Text("Receiving notifications • \(state.notificationsMirroredCount) mirrored this session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.peerFeatures.contains("file") {
                    Button(action: pickAndSendFile) {
                        Label("Send file", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var recentNotificationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent notifications").font(.headline)
                    Spacer()
                    if history.entries.count > 5 {
                        Button {
                            MainWindowSelection.shared.pending = .notifications
                        } label: {
                            HStack(spacing: 4) {
                                Text("See all"); Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                }

                if history.entries.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash").foregroundStyle(.secondary)
                        Text("Nothing yet — notifications from your phone will land here.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                } else {
                    let recent = Array(history.entries.prefix(5))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, entry in
                        OverviewNotificationRow(entry: entry) {
                            MainWindowSelection.shared.pending = .notifications
                            MainWindowSelection.shared.pendingNotificationKey = entry.key
                        }
                        if idx < recent.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                nowPlayingArtwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.media.title ?? state.media.app ?? "Now playing")
                        .font(.headline).lineLimit(1)
                    if let artist = state.media.artist, !artist.isEmpty {
                        Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    } else if let app = state.media.app, !app.isEmpty {
                        Text(app).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Button { MediaController.shared.send(cmd: "prev") } label: {
                            Image(systemName: "backward.fill")
                        }.disabled(!state.media.canSkipPrev)
                        Button { MediaController.shared.send(cmd: "toggle") } label: {
                            Image(systemName: state.media.playing ? "pause.fill" : "play.fill")
                        }
                        Button { MediaController.shared.send(cmd: "next") } label: {
                            Image(systemName: "forward.fill")
                        }.disabled(!state.media.canSkipNext)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var nowPlayingArtwork: some View {
        if let b64 = state.media.artworkBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable().interpolation(.medium).scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    private func activeTransfersCard(items: [TransferProgress]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Active transfers").font(.headline)
                ForEach(items, id: \.id) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.direction == .incoming
                              ? "arrow.down.circle.fill"
                              : "arrow.up.circle.fill")
                            .foregroundStyle(t.direction == .incoming ? .blue : .green)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).lineLimit(1)
                            ProgressView(value: progressValue(t)).frame(maxWidth: .infinity)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func progressValue(_ t: TransferProgress) -> Double {
        t.size > 0 ? min(1, Double(t.bytesTransferred) / Double(t.size)) : 0
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
}

private struct OverviewNotificationRow: View {
    let entry: NotificationHistory.Entry
    let onOpen: () -> Void
    @State private var copiedCode = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.app).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.receivedAt,
                         format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !entry.title.isEmpty {
                    Text(entry.title).font(.body.weight(.semibold)).lineLimit(1)
                }
                if !entry.body.isEmpty {
                    Text(entry.body).font(.body).lineLimit(2)
                }
                if let code = entry.extractedCode {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(code, forType: .string)
                        copiedCode = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedCode = false }
                    } label: {
                        Label(copiedCode ? "Copied" : "Copy code \(code)",
                              systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help("Click to open in Notifications")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
        }
    }
}

extension NotificationHistory.Entry {
    /// Best-guess verification code in `body`. Multilingual keyword-aware
    /// extractor ported from jd1378/otphelper (MIT — github.com/jd1378/otphelper).
    var extractedCode: String? {
        guard !body.isEmpty else { return nil }
        return CodeExtractor.shared.code(in: body)
    }
}

final class CodeExtractor {
    static let shared = CodeExtractor()

    private let sensitivePhrases: [String] = [
        "code",
        #"One[-\s]Time[-\s]Password"#, #"One[-\s]Time[-\s]Code"#,
        "کد", "رمز",
        #"\bOTP\W"#, #"\b2FA\W"#,
        "Einmalkennwort",
        "contraseña", #"c[oó]digo"#, "clave", #"\bel siguiente PIN\W"#,
        "验证码", "校验码", "識別碼", "認證", "驗證",
        "код",
        "סיסמ", #"\bהקוד\W"#, #"\bקוד\W"#,
        #"\bKodu\W"#, #"\bKodunuz\W"#, #"\b[sş]ifre\W"#,
        #"\bparola\W"#, #"\bdo[ğg]rulama\W"#, #"\bonay\W"#, #"\bg[uü]venlik\W"#,
        #"\bgiri[sş]\W"#, #"\baktivasyon\W"#, #"\btek[-\s]kullan[ıi]ml[ıi]k\W"#,
        #"\bKodi\W"#, #"\bKods\W"#,
        #"\b(?:m|sms)?TAN\W"#,
        #"\bcodice\W"#,
        "コード", "パスワード", "認証番号", "ワンタイム",
        #"\bvahvistuskoodi"#, #"\bkertakäyttökoodisi\W"#,
        #"\bkod\W"#, #"\bautoryzacji\W"#,
        #"Parol\s+dlya\s+podtverzhdeniya"#, #"\bпароль\W"#,
        "인증번호",
        "code secret", "code de vérification", "code de validation",
        "code de confirmation", "mot de passe", "code de sécurité",
        "code d'accès",
        "código de verificação", "código de confirmação",
        "código de segurança", "senha", "palavra-passe",
        "verificatiecode", "bevestigingscode", "inlogcode",
        "toegangscode", "wachtwoord",
        "verifieringskod", "engångskod", "säkerhetskod", "bekräftelsekod",
        "verifiseringskode", "engangskode", "sikkerhetskode",
        "verificeringskode", "engangskode", "sikkerhedskode",
        "κωδικός", "κωδικός επαλήθευσης", "κωδικός πρόσβασης",
        "รหัส", "รหัสยืนยัน", "รหัสผ่าน", "รหัส OTP",
        "mã xác nhận", "mã xác thực", "mật khẩu", "mã OTP",
        "رمز التحقق", "رمز التأكيد", "كلمة المرور", "رمز الدخول",
        "कोड", "पासवर्ड", "ओटीपी",
        "kode verifikasi", "kode pengesahan", "kata laluan",
        "kod pengesahan", "kata sandi",
        "cod de verificare", "cod de confirmare",
        "код підтвердження", "пароль",
        "megerősítő kód", "ellenőrző kód", "jelszó",
        "ověřovací kód", "overovací kód", "heslo",
        "কোড", "পাসওয়ার্ড", "ওটিপি",
        "ઓટીપી", "કોડ", "પાસવર્ડ",
        "ಕೋಡ್", "ಪಾಸ್ವರ್ಡ್",
    ]

    private let skipPhrases: [String] = [
        "مقدار", "مبلغ", "amount", "برای", "-ارز",
        #"\bindirim\W"#, #"\bkampanya\W"#, #"\bpromosyon\W"#,
        #"\bbakiyeniz\W"#, #"\bbakiye\W"#,
        #"\bTutar\W"#, #"\bFiyat\W"#, #"\bÜcret\W"#,
        "[a-zA-Z0-9] [a-zA-Z0-9] [a-zA-Z0-9] [a-zA-Z0-9] ?",
    ]

    private let currencyIndicators: [String] = [
        "USD", "EUR", "GBP", "TRY", "TL", #"[$€£₺]"#,
    ]

    private let nonCodeIndicators: [String] = [
        #"\b\d{1,2}[./]\d{1,2}[./]?\d{0,4}\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b\d+[.,]\d{2}\b"#,
        #"\b\d{9,}\b"#,
        #"%\d+"#, #"\d+%"#,
        #"\b\d{4,6}\s?(?:K?B|MB|GB|TB)\b"#,
    ]

    private let cleanupPhrases: [String] = [
        #"[a-zA-Z0-9][a-zA-Z0-9-]{0,61}\.[a-zA-Z]{2,}(?:[.a-zA-Z]{0,3}(?=\s+)|)"#,
        #"['"]"#,
        #"Endziffer-\d+"#,
        #"Ending \d+"#,
        "<#>",
        "share OTP",
    ]

    private let ignoredPhrases: [String] = [
        "تخفیف", "takhfif", "off", "اشتباه وارد شده",
        "RatingCode", "vscode", "versionCode", "unicode",
        "discount code", "fancode", "encode", "decode",
        "barcode", "codex",
        "kargo", "takip", "sipariş", "fatura",
    ]

    private let generalMatcher: NSRegularExpression?
    private let specialMatcher: NSRegularExpression?
    private let cleanupMatcher: NSRegularExpression?
    private let ignoredMatcher: NSRegularExpression?
    private let standaloneMatcher: NSRegularExpression?
    private let bracketMatcher: NSRegularExpression?
    private let nonCodeMatcher: NSRegularExpression?

    private init() {
        let opts: NSRegularExpression.Options = [.caseInsensitive, .anchorsMatchLines]
        let sensitive = sensitivePhrases.joined(separator: "|")
        let skip = skipPhrases.joined(separator: "|")
        let currency = currencyIndicators.joined(separator: "|")

        let general = #"(\#(sensitive))(?:\s*(?!\#(skip))(?:[^\s:：܃︓﹕.'"\d٠-٩۰-۹]|[\d٠-٩۰-۹,\s]+(?:\#(currency))|[\d٠-٩۰-۹][^\d٠-٩۰-۹]))*\s*[:：܃︓﹕]?\s*(["'「]?)([\d٠-٩۰-۹a-zA-Z\-]{4,}|(?: [\d٠-٩۰-۹a-zA-Z]){4,}|)\1?(?:[^\d٠-٩۰-۹a-zA-Z]|$)"#

        let special = #"((?:[\d٠-٩۰-۹]-?){4,}(?=\s)|[\d٠-٩۰-۹ ]{4,}(?=\s)|[\d٠-٩۰-۹]{4,})[^:]*(\#(sensitive))"#

        let standalone = #"(?:^|\n)\s*(["'「\[\(\{]*)((?:[\d٠-٩۰-۹][\- ]?){3,}[\d٠-٩۰-۹])\1\s*(?:$|\n)"#

        let bracket = #"[\[\(\{]([\d٠-٩۰-۹a-zA-Z\-]{4,})[\]\)\}]"#

        self.generalMatcher = try? NSRegularExpression(pattern: general, options: opts)
        self.specialMatcher = try? NSRegularExpression(pattern: special, options: opts)
        self.standaloneMatcher = try? NSRegularExpression(pattern: standalone, options: opts)
        self.bracketMatcher = try? NSRegularExpression(pattern: bracket, options: opts)
        self.cleanupMatcher = try? NSRegularExpression(
            pattern: #"(\#(cleanupPhrases.joined(separator: "|")))"#,
            options: opts
        )
        self.ignoredMatcher = try? NSRegularExpression(
            pattern: #"\b(\#(ignoredPhrases.joined(separator: "|")))\b"#,
            options: opts
        )
        self.nonCodeMatcher = try? NSRegularExpression(
            pattern: nonCodeIndicators.joined(separator: "|"),
            options: opts
        )
    }

    func code(in body: String) -> String? {
        let bodyNs = body as NSString
        if let ignored = ignoredMatcher,
           ignored.firstMatch(in: body, range: NSRange(location: 0, length: bodyNs.length)) != nil {
            return nil
        }

        let cleaned = cleanup(body)
        let ns = cleaned as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let result = keywordBasedCode(in: cleaned, ns: ns, full: full) {
            return result
        }

        if let result = standaloneOrBracketCode(in: cleaned, ns: ns, body: body) {
            return result
        }

        return nil
    }

    private func keywordBasedCode(in cleaned: String, ns: NSString, full: NSRange) -> String? {
        if let general = generalMatcher {
            let matches = general.matches(in: cleaned, range: full)
            for m in matches where m.numberOfRanges >= 4 {
                let codeRange = m.range(at: 3)
                guard codeRange.location != NSNotFound, codeRange.length > 0 else { continue }
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if !normalized.isEmpty {
                    return toEnglishNumbers(normalized)
                }
            }
        }

        if let special = specialMatcher,
           let m = special.firstMatch(in: cleaned, range: full),
           m.numberOfRanges >= 2 {
            let codeRange = m.range(at: 1)
            if codeRange.location != NSNotFound {
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if !normalized.isEmpty {
                    return toEnglishNumbers(normalized)
                }
            }
        }
        return nil
    }

    private func standaloneOrBracketCode(in cleaned: String, ns: NSString, body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count

        if charCount <= 6 {
            let digitsOnly = trimmed.filter { $0.isNumber || $0 == "-" || $0 == " " }
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            if digitsOnly.count >= 4, digitsOnly.count <= 8,
               digitsOnly.allSatisfy({ $0.isNumber }) {
                return toEnglishNumbers(digitsOnly)
            }
        }

        if let bracket = bracketMatcher,
           let m = bracket.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 2 {
            let codeRange = m.range(at: 1)
            if codeRange.location != NSNotFound, codeRange.length > 0 {
                let normalized = ns.substring(with: codeRange)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                let english = toEnglishNumbers(normalized)
                if !english.isEmpty,
                   english.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil {
                    return english
                }
            }
        }

        if let standalone = standaloneMatcher,
           let m = standalone.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 3 {
            let codeRange = m.range(at: 2)
            if codeRange.location != NSNotFound, codeRange.length > 0 {
                let matched = ns.substring(with: codeRange)
                let normalized = matched
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                if normalized.count >= 4, normalized.count <= 8,
                   normalized.allSatisfy({ $0.isNumber }),
                   nonCodeMatcher?.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) == nil {
                    return toEnglishNumbers(normalized)
                }
            }
        }

        return nil
    }

    private func cleanup(_ str: String) -> String {
        guard let regex = cleanupMatcher else { return str }
        let ns = str as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: str, range: range, withTemplate: "")
    }

    private func toEnglishNumbers(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0x0660 && v <= 0x0669 {
                result.unicodeScalars.append(Unicode.Scalar(v - 0x0660 + 0x30)!)
            } else if v >= 0x06F0 && v <= 0x06F9 {
                result.unicodeScalars.append(Unicode.Scalar(v - 0x06F0 + 0x30)!)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Pairing pane

private struct PairingPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PaneContainer("Pairing",
                      subtitle: "Scan this code from your Android phone to link it with this Mac.") {
            ScrollView {
                VStack(spacing: 18) {
                    if state.isClientConnected {
                        connected
                    } else {
                        qrBlock
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var connected: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .resizable().scaledToFit().frame(width: 56, height: 56)
                    .foregroundStyle(.green)
                Text("Connected").font(.title.weight(.semibold))
                if let n = state.pairedDeviceName {
                    Text(n).font(.title3).foregroundStyle(.secondary)
                }
                Text("Mirroring is active — notifications will appear on your Mac as they arrive.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Regenerate secret", role: .destructive) {
                        _ = Pairing.shared.regenerateSecret()
                        WsServer.shared.restartListener()
                        state.pairingRevision &+= 1
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var qrBlock: some View {
        if let payload = makePayload() {
            Card {
                VStack(spacing: 14) {
                    QRCodeView(payload: payload)
                        .id(state.pairingRevision)
                        .frame(width: 240, height: 240)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        infoRow(symbol: "network", label: "Host",
                                value: LocalAddress.currentLanIPv4())
                        infoRow(symbol: "number.circle", label: "Port",
                                value: state.listenerPort == 0 ? "(starting…)" : String(state.listenerPort))
                        infoRow(symbol: "laptopcomputer", label: "Mac",
                                value: Host.current().localizedName ?? "Mac")
                    }
                    .frame(maxWidth: 340, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(payload, forType: .string)
                        } label: {
                            Label("Copy JSON", systemImage: "doc.on.doc")
                        }

                        Button(role: .destructive) {
                            _ = Pairing.shared.regenerateSecret()
                            WsServer.shared.restartListener()
                            state.pairingRevision &+= 1
                        } label: {
                            Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Card {
                ProgressView("Starting server…")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }

    private func infoRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func makePayload() -> String? {
        guard state.listenerPort != 0 else { return nil }
        return Pairing.shared.payloadJSON(
            host: LocalAddress.currentLanIPv4(),
            port: Int(state.listenerPort)
        )
    }
}

// MARK: - Notifications pane (history)

private struct NotificationsPane: View {
    @StateObject private var history = NotificationHistory.shared
    @StateObject private var blockedApps = BlockedApps.shared
    @ObservedObject private var selectionBridge = MainWindowSelection.shared
    @State private var query: String = ""
    @State private var selectedPkg: String? = nil
    @State private var highlightedKey: String? = nil

    var body: some View {
        PaneContainer("Notifications",
                      subtitle: history.entries.isEmpty
                          ? "Mirrored notifications will appear here as they arrive."
                          : "Showing \(filtered.count) of \(history.entries.count)") {
            HSplitView {
                appsSidebar
                    .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)

                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            history.entries.isEmpty ? "No notifications yet" : "No matches",
                            systemImage: "bell.slash",
                            description: Text(history.entries.isEmpty
                                ? "Mirrored notifications will appear here as they arrive."
                                : "Try a different search or filter.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(filtered) { entry in
                                        HistoryEntryRow(entry: entry,
                                                        highlighted: highlightedKey == entry.key,
                                                        onDelete: { history.remove(entry) })
                                            .id(entry.id)
                                            .onTapGesture {
                                                // Any click in the list dismisses the
                                                // "you opened this one" highlight.
                                                if highlightedKey != nil { highlightedKey = nil }
                                            }
                                        Divider()
                                    }
                                }
                            }
                            // .task(id:) fires both on first appearance with the
                            // current id and on every subsequent change. More
                            // reliable than .onAppear + .onChange when the pane
                            // is being mounted right as the value is set (which
                            // is exactly the notification-click flow).
                            .task(id: selectionBridge.pendingNotificationKey) {
                                await consumePendingKey(proxy: proxy)
                            }
                        }
                    }
                }
                .frame(minWidth: 360)
            }
        }
    }

    @MainActor
    private func consumePendingKey(proxy: ScrollViewProxy) async {
        guard let key = selectionBridge.pendingNotificationKey else { return }
        // Claim the key immediately so the task doesn't re-run on the
        // resulting id change before we've finished.
        selectionBridge.pendingNotificationKey = nil

        NSLog("NotificationsPane: opening on key=\(key) (\(history.entries.count) entries in history)")

        // Clear filters so the entry is definitely visible.
        if !query.isEmpty { query = "" }
        if selectedPkg != nil { selectedPkg = nil }

        guard let target = history.entries.first(where: { $0.key == key }) else {
            NSLog("NotificationsPane: no history entry matches key=\(key)")
            return
        }
        highlightedKey = key

        // LazyVStack only materializes visible rows, so scrollTo can fail to
        // find the target if we call it before SwiftUI has had a chance to
        // lay things out. A short pause lets the list settle.
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Search title, body or app", text: $query)
                .textFieldStyle(.roundedBorder)
            Spacer()
            Button(role: .destructive) {
                if let pkg = selectedPkg {
                    history.clear(pkg: pkg)
                    selectedPkg = nil
                } else {
                    history.clear()
                }
            } label: {
                Label(clearButtonLabel, systemImage: "trash")
            }
            .disabled(clearButtonDisabled)
        }
        .padding(12)
    }

    private var selectedAppName: String? {
        guard let pkg = selectedPkg else { return nil }
        return history.entries.first { $0.pkg == pkg }?.app
    }

    private var clearButtonLabel: String {
        if let name = selectedAppName { return "Clear \(name)" }
        return "Clear all"
    }

    private var clearButtonDisabled: Bool {
        if let pkg = selectedPkg {
            return !history.entries.contains { $0.pkg == pkg }
        }
        return history.entries.isEmpty
    }

    private var appsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps")
                .font(.headline)
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sidebarRow("All", pkg: nil, count: history.entries.count)
                    Divider()
                    ForEach(appsByCount, id: \.pkg) { row in
                        sidebarRow(row.name, pkg: row.pkg, count: row.count)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarRow(_ label: String, pkg: String?, count: Int) -> some View {
        let isBlocked = pkg.map { blockedApps.isBlocked($0) } ?? false
        return HStack(spacing: 6) {
            Text(label)
                .lineLimit(1)
                .foregroundStyle(isBlocked ? .secondary : .primary)
                .strikethrough(isBlocked, color: .secondary)
            Spacer(minLength: 4)
            Text("\(count)").foregroundStyle(.secondary).font(.callout)
            if let pkg {
                Button {
                    blockedApps.setBlocked(pkg, blocked: !isBlocked)
                } label: {
                    Image(systemName: isBlocked ? "bell.slash.fill" : "bell")
                        .foregroundStyle(isBlocked ? Color.orange : Color.secondary)
                        .font(.callout)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isBlocked ? "Unmute notifications from \(label)" : "Mute notifications from \(label)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selectedPkg == pkg ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { selectedPkg = pkg }
        .contextMenu {
            if let pkg {
                Button(isBlocked ? "Unmute \(label)" : "Mute \(label)") {
                    blockedApps.setBlocked(pkg, blocked: !isBlocked)
                }
            }
        }
    }

    private var appsByCount: [(pkg: String, name: String, count: Int)] {
        var counts: [String: (name: String, count: Int, lastAt: Date)] = [:]
        for e in history.entries {
            if var cur = counts[e.pkg] {
                cur.count += 1
                cur.name = e.app
                if e.receivedAt > cur.lastAt { cur.lastAt = e.receivedAt }
                counts[e.pkg] = cur
            } else {
                counts[e.pkg] = (name: e.app, count: 1, lastAt: e.receivedAt)
            }
        }
        return counts
            .map { (pkg: $0.key, name: $0.value.name, count: $0.value.count, lastAt: $0.value.lastAt) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
                return $0.pkg < $1.pkg
            }
            .map { (pkg: $0.pkg, name: $0.name, count: $0.count) }
    }

    private var filtered: [NotificationHistory.Entry] {
        var list = history.entries
        if let pkg = selectedPkg { list = list.filter { $0.pkg == pkg } }
        if !query.isEmpty {
            let q = query.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) ||
                $0.body.lowercased().contains(q) ||
                $0.app.lowercased().contains(q) ||
                $0.pkg.lowercased().contains(q)
            }
        }
        return list
    }
}

private struct HistoryEntryRow: View {
    let entry: NotificationHistory.Entry
    var highlighted: Bool = false
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.app).font(.callout).foregroundStyle(.secondary)
                    if entry.silent {
                        Text("silent")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.18))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.receivedAt, format: relativeFormat)
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if !entry.title.isEmpty {
                    Text(entry.title).font(.body.weight(.semibold))
                }
                if !entry.body.isEmpty {
                    Text(entry.body).font(.body).lineLimit(4)
                }
                if let code = entry.extractedCode {
                    CodeChip(code: code, onCopy: { copy(code) })
                        .padding(.top, 2)
                }
                if let actions = entry.actions, !actions.isEmpty {
                    HistoryActionBar(key: entry.key, actions: actions)
                        .padding(.top, 4)
                }
            }
            .textSelection(.enabled)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .opacity(0.6)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(highlighted ? 0.28 : 0))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 4)
                .opacity(highlighted ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .contentShape(Rectangle())
        .contextMenu {
            if let code = entry.extractedCode { Button("Copy code \(code)") { copy(code) } }
            if !entry.title.isEmpty { Button("Copy title") { copy(entry.title) } }
            if !entry.body.isEmpty { Button("Copy body") { copy(entry.body) } }
            Button("Copy title + body") {
                let text = [entry.title, entry.body].filter { !$0.isEmpty }.joined(separator: "\n")
                copy(text)
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Text("Delete") }
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private var relativeFormat: Date.RelativeFormatStyle {
        Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.attachmentPath,
           FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.gray.opacity(0.18))
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
            }
            .frame(width: 52, height: 52)
        }
    }
}

private struct HistoryActionBar: View {
    let key: String
    let actions: [ActionDescriptor]

    @State private var openReplyId: String? = nil
    @State private var replyText: String = ""
    @State private var sentLabel: String? = nil
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(actions, id: \.id) { action in
                    Button {
                        if action.isReply {
                            if openReplyId == action.id {
                                openReplyId = nil
                            } else {
                                openReplyId = action.id
                                replyText = ""
                                // Wait one tick so the TextField has a chance
                                // to mount before grabbing focus.
                                DispatchQueue.main.async { replyFocused = true }
                            }
                        } else {
                            send(action: action, text: nil)
                        }
                    } label: {
                        Label(action.title,
                              systemImage: action.isReply
                                  ? "arrowshape.turn.up.left.fill"
                                  : "bolt.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                if let sent = sentLabel {
                    Label("\(sent) sent", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            if let actionId = openReplyId,
               let action = actions.first(where: { $0.id == actionId }) {
                HStack(spacing: 8) {
                    TextField("Type a reply…", text: $replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .onSubmit {
                            if !replyText.isEmpty { send(action: action, text: replyText) }
                        }
                    Button("Send") { send(action: action, text: replyText) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(replyText.isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Cancel") {
                        openReplyId = nil
                        replyText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }

    private func send(action: ActionDescriptor, text: String?) {
        WsServer.shared.sendAction(key: key, actionId: action.id, text: text)
        let label = action.title
        sentLabel = label
        openReplyId = nil
        replyText = ""
        // Auto-clear the "sent" indicator after a short delay so it doesn't
        // linger forever and confuse the next interaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if sentLabel == label { sentLabel = nil }
        }
    }
}

private struct CodeChip: View {
    let code: String
    let onCopy: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            onCopy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                Text(copied ? "Copied" : "Copy code \(code)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(copied ? 0.28 : 0.16))
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mirrored apps pane

private struct MirroredAppsPane: View {
    @StateObject private var store = BlockedApps.shared
    @StateObject private var prefs = Preferences.shared
    @State private var query: String = ""

    var body: some View {
        PaneContainer("Mirrored Apps",
                      subtitle: "Turn off any app you don't want mirrored to this Mac.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controlsCard
                    listArea
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
    }

    private var controlsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $prefs.hideSilent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide silent notifications")
                        Text("Drop banners from low / min importance channels on Android")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 12) {
                    TextField("Search app name or package", text: $query)
                        .textFieldStyle(.roundedBorder)
                    if !store.seen.isEmpty {
                        Button("Clear seen", role: .destructive) { store.clearSeen() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listArea: some View {
        if store.seen.isEmpty {
            ContentUnavailableView(
                "No apps seen yet",
                systemImage: "bell.slash",
                description: Text("Apps appear here the first time they send a notification from your phone.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 28)
        } else {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, app in
                        appRow(app)
                        if idx < filtered.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func appRow(_ app: BlockedApps.SeenApp) -> some View {
        Toggle(isOn: bindingFor(app)) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(app.name.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.body)
                    Text(app.pkg).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 6)
    }

    private var filtered: [BlockedApps.SeenApp] {
        let base = store.seen.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { $0.name.lowercased().contains(q) || $0.pkg.lowercased().contains(q) }
    }

    private func bindingFor(_ app: BlockedApps.SeenApp) -> Binding<Bool> {
        Binding(
            get: { !store.isBlocked(app.pkg) },
            set: { enabled in store.setBlocked(app.pkg, blocked: !enabled) }
        )
    }
}

// MARK: - Clipboard pane

private struct ClipboardPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Preferences.shared

    private var featureAvailable: Bool {
        state.peerFeatures.contains("clip")
    }

    var body: some View {
        PaneContainer("Clipboard",
                      subtitle: "Share text and images between this Mac and your phone.") {
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Enable clipboard sync", isOn: $prefs.clipboardSyncEnabled)
                                .toggleStyle(.switch)
                                .disabled(!featureAvailable)

                            if !featureAvailable {
                                Text("Your phone hasn't advertised clipboard support yet. Make sure NotifMirror is running on both devices.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("When enabled, clipboard text is mirrored between devices in both directions.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Last activity").font(.headline)
                            if let dir = state.lastClipDirection, let at = state.lastClipAt {
                                HStack(spacing: 10) {
                                    Image(systemName: dir == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(dir == .incoming ? "From phone" : "To phone")
                                    Spacer()
                                    Text(relative(at)).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No clipboard syncs yet.").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Media pane

private struct MediaPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var prefs = Preferences.shared
    @State private var pendingVolume: Double? = nil

    var body: some View {
        PaneContainer("Media",
                      subtitle: "Control what's playing on your phone from this Mac.") {
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        Toggle("Enable media control", isOn: $prefs.mediaControlEnabled)
                            .toggleStyle(.switch)
                    }

                    if prefs.mediaControlEnabled && state.peerFeatures.contains("media") {
                        Card { player }
                    } else {
                        Card {
                            HStack {
                                Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
                                Text(prefs.mediaControlEnabled
                                     ? "Waiting for media support from phone…"
                                     : "Media control is turned off.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
        .onChange(of: state.media.volume) { _, _ in pendingVolume = nil }
    }

    @ViewBuilder
    private var player: some View {
        if state.media.hasSession {
            HStack(alignment: .top, spacing: 16) {
                artwork.frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    Text(state.media.title ?? state.media.app ?? "Playing")
                        .font(.title3.weight(.semibold)).lineLimit(2)
                    if let artist = state.media.artist, !artist.isEmpty {
                        Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let app = state.media.app, !app.isEmpty {
                        Text(app).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
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

                    if state.media.maxVolume > 0 { volumeSlider }
                }
            }
        } else {
            HStack {
                Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                Text("No media playing").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { MediaController.shared.refresh() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let b64 = state.media.artworkBase64,
           let data = Data(base64Encoded: b64),
           let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "music.note").foregroundStyle(.secondary).font(.title)
            }
        }
    }

    private var volumeSlider: some View {
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
            Text("\(Int(current))/\(Int(maxV))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func transportButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(minWidth: 50)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

// MARK: - Transfers pane

private struct TransfersPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PaneContainer("File Transfers",
                      subtitle: "Send files to your phone and see incoming transfers.") {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    HStack(spacing: 10) {
                        Button(action: pickAndSend) {
                            Label("Send file to phone…", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Clear finished") {
                            state.transfers = state.transfers.filter {
                                switch $1.status {
                                case .done, .failed, .cancelled: return false
                                default: return true
                                }
                            }
                        }
                        .disabled(!hasFinished)
                        Spacer()
                    }
                }

                if state.transfers.isEmpty {
                    ContentUnavailableView(
                        "No transfers",
                        systemImage: "arrow.up.arrow.down.circle",
                        description: Text("Drop-to-phone files show up here while they upload.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    Card {
                        VStack(spacing: 0) {
                            let items = state.transfers.values.sorted { $0.name < $1.name }
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, t in
                                TransferRow(transfer: t)
                                if idx < items.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        }
    }

    private var hasFinished: Bool {
        state.transfers.values.contains {
            switch $0.status {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    private func pickAndSend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            FileTransferCenter.shared.sendFile(url: url)
        }
    }
}

private struct TransferRow: View {
    let transfer: TransferProgress

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .incoming
                  ? "arrow.down.circle.fill"
                  : "arrow.up.circle.fill")
                .foregroundStyle(transfer.direction == .incoming ? .blue : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).lineLimit(1)
                ProgressView(value: progress).frame(maxWidth: 320)
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private var progress: Double {
        transfer.size > 0
            ? min(1, Double(transfer.bytesTransferred) / Double(transfer.size))
            : 0
    }

    private var statusLabel: String {
        switch transfer.status {
        case .pending: return "waiting"
        case .active:
            let pct = transfer.size > 0
                ? Int(Double(transfer.bytesTransferred) / Double(transfer.size) * 100)
                : 0
            return "\(pct)% • \(byteString(transfer.bytesTransferred)) / \(byteString(transfer.size))"
        case .done: return "done"
        case .failed(let m): return "failed: \(m)"
        case .cancelled: return "cancelled"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Settings pane

private struct SettingsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var appState = AppState.shared
    @State private var inboxPathEditing: String = ""
    @State private var notifDiagnostic: NotifDiagnostic? = nil
    @State private var e2eDiagnostic: NotifDiagnostic? = nil
    @State private var e2ePending: Bool = false

    private struct NotifDiagnostic: Identifiable {
        let id = UUID()
        let ok: Bool
        let message: String
    }

    var body: some View {
        PaneContainer("Settings", subtitle: "Customize NotifMirror.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalCard
                    diagnosticsCard
                    featuresCard
                    filesCard
                    dangerCard
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
        .onAppear { inboxPathEditing = prefs.fileInboxPath }
    }

    private var generalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("General").font(.headline)
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle("Hide silent notifications", isOn: $prefs.hideSilent)
                    .toggleStyle(.switch)
            }
        }
    }

    private var featuresCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Features").font(.headline)
                Toggle("Clipboard sync", isOn: $prefs.clipboardSyncEnabled)
                    .toggleStyle(.switch)
                Toggle("Media control", isOn: $prefs.mediaControlEnabled)
                    .toggleStyle(.switch)
            }
        }
    }

    private var filesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Incoming files").font(.headline)
                Text("Files sent from your phone are saved here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Path", text: $inboxPathEditing, onCommit: {
                        prefs.fileInboxPath = inboxPathEditing
                    })
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseInbox() }
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(nil,
                            inFileViewerRootedAtPath: prefs.fileInboxPath)
                    }
                }
            }
        }
    }

    private var dangerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pairing").font(.headline)
                Text("Regenerating the secret invalidates the current pairing and requires you to scan the QR again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    _ = Pairing.shared.regenerateSecret()
                    WsServer.shared.restartListener()
                    AppState.shared.pairingRevision &+= 1
                    MainWindowSelection.shared.pending = .pairing
                } label: {
                    Label("Regenerate pairing secret", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notifications").font(.headline)
                Text("Send a local test banner. If it doesn't appear, macOS is suppressing NotifMirror banners (check Focus Mode, Do Not Disturb, or the \"Deliver Quietly\" option).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await sendTestNotification() }
                    } label: {
                        Label("Send test notification", systemImage: "bell.and.waves.left.and.right")
                    }
                    Button {
                        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                            ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open Notification Settings", systemImage: "gear")
                    }
                }
                if let diag = notifDiagnostic {
                    Label(diag.message,
                          systemImage: diag.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(diag.ok ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 2)

                Text("End-to-end test").font(.subheadline).bold()
                Text("Asks the paired Android to fire a real notification from the NotifMirror app. The phone's notification listener should catch it and mirror it back, exercising the full WS round-trip and the on-device listener path — not just local macOS delivery.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await sendEndToEndTest() }
                    } label: {
                        if e2ePending {
                            Label("Waiting for Android…", systemImage: "hourglass")
                        } else {
                            Label("Run end-to-end test", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(e2ePending || !appState.isClientConnected)
                    if !appState.isClientConnected {
                        Text("Android not connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let diag = e2eDiagnostic {
                    Label(diag.message,
                          systemImage: diag.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(diag.ok ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func sendEndToEndTest() async {
        guard appState.isClientConnected else {
            e2eDiagnostic = .init(ok: false, message: "Not connected to Android.")
            return
        }
        // 8-char nonce — long enough that two concurrent tests can't collide,
        // short enough to read in a debug log if a test ever fails.
        let reqId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        appState.pendingE2ETestReqId = reqId
        e2eDiagnostic = nil
        e2ePending = true
        defer { e2ePending = false }

        WsServer.shared.sendTestRequest(reqId: reqId)

        // Poll AppState for the WS receive loop clearing the marker; this
        // avoids wiring up a Combine sink just for one transient signal.
        let started = Date()
        let timeout: TimeInterval = 5.0
        while Date().timeIntervalSince(started) < timeout {
            if appState.pendingE2ETestReqId != reqId {
                e2eDiagnostic = .init(ok: true,
                    message: "Round-trip OK — Android posted, listener caught it, Mac received the mirror in \(Int((Date().timeIntervalSince(started)) * 1000)) ms.")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Still pending — clear and report timeout.
        if appState.pendingE2ETestReqId == reqId {
            appState.pendingE2ETestReqId = nil
        }
        e2eDiagnostic = .init(ok: false,
            message: "No matching `posted` arrived within \(Int(timeout))s. Either Android didn't receive the test request, didn't have notification access granted, or the listener isn't bound. Check the phone's logs.")
    }

    @MainActor
    private func sendTestNotification() async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()

        // If macOS says we haven't asked yet, ask now — in direct response
        // to a user click. The launch-time request in AppDelegate runs in a
        // background Task before the user interacts with the app, and for
        // LSUIElement menu-bar apps the system sometimes never surfaces
        // that prompt. A user-initiated request is reliable.
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                settings = await center.notificationSettings()
                if !granted {
                    notifDiagnostic = .init(ok: false,
                        message: "Permission prompt declined. Enable it in System Settings › Notifications › NotifMirror.")
                    return
                }
            } catch {
                notifDiagnostic = .init(ok: false,
                    message: "Authorization request failed: \(error.localizedDescription). \(Self.settingsDump(settings))")
                return
            }
        }

        // Pre-flight: surface known reasons the banner would be suppressed
        // before we even try to post. macOS silently accepts notifications
        // without ever showing a banner in several configurations, so add()
        // reporting "no error" is not a signal that delivery succeeded.
        switch settings.authorizationStatus {
        case .denied:
            notifDiagnostic = .init(ok: false,
                message: "Notifications are disabled for NotifMirror. Open System Settings › Notifications › NotifMirror and turn them on. \(Self.settingsDump(settings))")
            return
        case .notDetermined:
            notifDiagnostic = .init(ok: false,
                message: "macOS still reports notDetermined after we asked. This usually means the app's code-signing identity changed between builds — reset it by running: tccutil reset All \(Bundle.main.bundleIdentifier ?? "com.notifmirror.app"). \(Self.settingsDump(settings))")
            return
        default:
            break
        }
        if settings.alertSetting == .disabled && settings.notificationCenterSetting == .disabled {
            notifDiagnostic = .init(ok: false,
                message: "Both banners and Notification Center are off for NotifMirror in System Settings › Notifications.")
            return
        }
        if settings.alertStyle == .none || settings.alertSetting == .disabled {
            notifDiagnostic = .init(ok: false,
                message: "Banner style is set to None. Pick Banners or Alerts in System Settings › Notifications › NotifMirror. (Notifications will still appear in Notification Center.)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "NotifMirror test"
        content.body = "If you see this banner, macOS delivery is working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "notifmirror.test.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            notifDiagnostic = .init(ok: true,
                message: "Test posted. \(Self.settingsDump(settings)) If no banner, the auth is fine but macOS is suppressing banners — check Focus/DND, \"Deliver Quietly\", or re-toggle \"Allow Notifications\" off→on in System Settings.")
        } catch {
            notifDiagnostic = .init(ok: false,
                message: "Failed to post notification: \(error.localizedDescription) \(Self.settingsDump(settings))")
        }
    }

    private static func settingsDump(_ s: UNNotificationSettings) -> String {
        // Raw rawValue legend:
        //   authorizationStatus: 0=notDetermined 1=denied 2=authorized 3=provisional 4=ephemeral
        //   alertSetting / notificationCenterSetting / soundSetting: 0=notSupported 1=disabled 2=enabled
        //   alertStyle: 0=none 1=banner 2=alert
        "[auth=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue) center=\(s.notificationCenterSetting.rawValue) sound=\(s.soundSetting.rawValue)]"
    }

    private func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: prefs.fileInboxPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.fileInboxPath = url.path
            inboxPathEditing = url.path
        }
    }
}

// MARK: - Screen mirror pane

private struct ScreenMirrorPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PaneContainer("Screen Mirror",
                      subtitle: "Project your phone screen to this Mac using scrcpy.") {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    requirementsCard
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
            }
        }
    }

    private var statusCard: some View {
        Card {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(state.scrcpyRunning
                              ? Color.green.opacity(0.22)
                              : Color.secondary.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: state.scrcpyRunning ? "display" : "display.trianglebadge.exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(state.scrcpyRunning ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.scrcpyRunning ? "Mirroring" : "Not mirroring")
                        .font(.title2.weight(.semibold))
                    Text(state.scrcpyRunning
                         ? "scrcpy is showing your phone. Close the window or tap Stop to end."
                         : "Launch scrcpy to project your phone screen onto this Mac.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    ScreenMirror.shared.toggle()
                } label: {
                    Label(state.scrcpyRunning ? "Stop" : "Start mirroring",
                          systemImage: state.scrcpyRunning ? "stop.circle.fill" : "play.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(state.scrcpyRunning ? .red : .accentColor)
            }
        }
    }

    private var requirementsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Requirements", systemImage: "checklist")
                    .font(.headline)

                bullet("`scrcpy` and `adb` installed — `brew install scrcpy`.")
                bullet("USB cable, or wireless debugging enabled on your phone (Developer options → Wireless debugging).")
                bullet("Phone must already be paired with this Mac via NotifMirror so its IP is known.")
            }
        }
    }

    private func bullet(_ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
            Text(.init(markdown))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
