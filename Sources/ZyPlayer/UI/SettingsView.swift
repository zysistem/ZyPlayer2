import SwiftUI
import AppKit

/// The settings panes, in the order they are listed.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, library, drive, subtitles, openSubtitles, stream, youtube, downloads,
         metadata, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Görünüm"
        case .library: "Kütüphane"
        case .drive: "Google Drive"
        case .subtitles: "Altyazı Görünümü"
        case .openSubtitles: "Altyazı Kaynakları"
        case .stream: "Akış Kaynakları"
        case .youtube: "YouTube"
        case .downloads: "İndirmeler"
        case .metadata: "Bilgi Kaynağı"
        case .about: "ZyPlayer Hakkında"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .library: "folder"
        case .drive: "cloud"
        case .subtitles: "captions.bubble"
        case .openSubtitles: "text.magnifyingglass"
        case .stream: "play.tv"
        case .youtube: "play.rectangle"
        case .downloads: "arrow.down.circle"
        case .metadata: "sparkles"
        case .about: "info.circle"
        }
    }
}

/// One collapsible row. Collapsed it shows a summary on the right, so the whole
/// page can be read at a glance without opening anything.
struct SettingsDisclosure<Content: View>: View {
    let section: SettingsSection
    let summary: String
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 11) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 20)

                    Text(section.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(16)
            }
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }
}

/// One row inside a section: icon, title, detail, trailing controls.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    var symbolColor: Color = .secondary
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A caption above a group of controls, so a long pane still has structure.
struct SettingsGroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
            .padding(.top, 2)
    }
}

struct SettingsView: View {
    let library: LibraryStore
    let smb: SMBStore
    let drive: GoogleDriveStore
    let torrents: TorrentStore
    @Bindable var settings: AppSettings
    /// Torrent devam kayıtlarını temizleyebilmek için.
    var resume: PlaybackResumeStore?

    /// Accordion: one pane open at a time. The old flat page showed every
    /// control at once, which is what made it hard to read.
    @State private var expanded: SettingsSection?
    @State private var showDriveCredentials = false
    @State private var showTMDBToken = false
    @State private var showDrivePicker = false
    @State private var newAddonURL = ""
    @State private var isProbingAddon = false
    @State private var addonMessage = ""
    @State private var translationCacheStats = TranslatedSubtitleCache.Stats(count: 0, bytes: 0)
    @State private var rememberedVideoCount = 0
    @State private var cacheClearedNote: String?
    @State private var torrentResumeClearedNote: String?
    @State private var isCheckingDomains = false
    @State private var domainCheckNote: String?
    @State private var currentImageCacheSize: String = ImageCacheManager.formattedCacheSize

    /// Hem çevirileri hem hatırlanan altyazı seçimlerini tek cümlede özetler.
    private var subtitleMemorySummary: String {
        let remembered = rememberedVideoCount > 0
            ? "\(rememberedVideoCount) içeriğin altyazı seçimi hatırlanıyor. "
            : ""
        return remembered + translationCacheStats.summary
            + " Eklediğiniz altyazılar ve çeviriler saklanır; aynı içeriği yeniden"
            + " açtığınızda seçiminizle birlikte geri gelir."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsDisclosure(
                        section: section,
                        summary: summary(for: section),
                        isExpanded: expanded == section,
                        toggle: { toggle(section) }
                    ) {
                        content(for: section)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        // The scroll view paints the stock window grey over the app gradient
        // unless it is told not to.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background(settings.colorScheme).ignoresSafeArea())
        .sheet(isPresented: $showDrivePicker) {
            DriveFolderPicker(
                drive: drive, settings: settings, library: library,
                onDone: { showDrivePicker = false }
            )
        }
    }

    private func toggle(_ section: SettingsSection) {
        withAnimation(.easeOut(duration: 0.18)) {
            expanded = expanded == section ? nil : section
        }
    }

    /// The right-hand text on a collapsed row.
    private func summary(for section: SettingsSection) -> String {
        switch section {
        case .appearance:
            return settings.appearance.title
        case .library:
            let active = library.folders.filter(\.isEnabled).count
            let shares = smb.shares.count
            var parts: [String] = []
            if active > 0 { parts.append("\(active) klasör") }
            if shares > 0 { parts.append("\(shares) paylaşım") }
            return parts.isEmpty ? "Kaynak yok" : parts.joined(separator: " · ")
        case .drive:
            if !drive.isConnected { return "Bağlı değil" }
            return settings.driveFolderID.isEmpty ? "Klasör seçilmedi" : settings.driveFolderName
        case .subtitles:
            return "\(settings.subtitleStyle.fontName) · \(settings.subtitleStyle.fontSize)"
        case .openSubtitles:
            let active = settings.enabledSubtitleAddons.count
            if active == 0 { return settings.hasOpenSubtitlesKey ? "Yalnızca hesap" : "Kaynak yok" }
            return "\(active) ücretsiz kaynak"
        case .stream:
            let active = settings.streamSources.filter(\.isEnabled).count
            return active == 0 ? "Kapalı" : "\(active) kaynak açık"
        case .youtube:
            return settings.youtubeSearchEnabled ? "Aramada açık" : "Kapalı"
        case .downloads:
            return torrents.isEngineAvailable
                ? (settings.downloadDirectory as NSString).lastPathComponent
                : "aria2 kurulu değil"
        case .metadata:
            guard settings.hasTMDBToken else { return "Jeton yok" }
            return settings.metadataLanguage == "tr-TR" ? "Türkçe" : "English"
        case .about:
            return "Sürüm \(AppInfo.version)"
        }
    }

    @ViewBuilder
    private func content(for section: SettingsSection) -> some View {
        switch section {
        case .appearance:     appearanceContent
        case .library:        libraryContent
        case .drive:          driveContent
        case .subtitles:      subtitleContent
        case .openSubtitles:  openSubtitlesContent
        case .stream:         streamContent
        case .youtube:        youtubeContent
        case .downloads:      downloadsContent
        case .metadata:       metadataContent
        case .about:          AboutView().frame(maxWidth: .infinity)
        }
    }

    // MARK: - Appearance

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Text("Uygulama seçtiğiniz temayı kullanır; sistem temasını izlemez.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Library (local folders + SMB)

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Kapatılan klasör listede kalır ama taranmaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if library.isScanning { ProgressView().controlSize(.small) }
                Button("Yeniden Tara") { Task { await library.rescan() } }
                    .disabled(library.folders.isEmpty || library.isScanning)
                Button("Klasör Ekle…") { chooseFolder() }
            }
            .controlSize(.small)

            if library.folders.isEmpty && settings.driveFolderID.isEmpty {
                Text("Henüz kaynak yok. Bir klasör ekleyin ya da Google Drive'a bağlanın.")
                    .foregroundStyle(.secondary)
            }

            ForEach(library.folders) { folder in
                SettingsRow(
                    symbol: folder.isEnabled ? "folder.fill" : "folder",
                    symbolColor: folder.isEnabled ? .accentColor : .secondary,
                    title: folder.url.lastPathComponent,
                    detail: folder.url.path
                ) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { folder.isEnabled },
                            set: { library.setFolder(folder, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(folder.isEnabled ? "Kapat" : "Aç")

                        Button {
                            library.removeFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Kaldır")
                    }
                }
            }

            // The Drive folder lives in the same list, so all sources read together.
            if !settings.driveFolderID.isEmpty {
                SettingsRow(
                    symbol: "arrow.down.left.and.arrow.up.right.circle.fill",
                    symbolColor: drive.isConnected ? .accentColor : .secondary,
                    title: settings.driveFolderName,
                    detail: drive.isConnected
                        ? "Google Drive · \(drive.accountFileCount) video"
                        : "Google Drive · bağlı değil"
                ) {
                    Button("Değiştir") { showDrivePicker = true }
                        .controlSize(.small)
                        .disabled(!drive.isConnected)
                }
            }

            Divider().opacity(0.5)

            HStack {
                SettingsGroupLabel(text: "Ağ Paylaşımları (SMB)")
                Spacer()
                if smb.isBusy { ProgressView().controlSize(.small) }
            }
            SMBSettingsView(library: library, smb: smb)
        }
    }

    // MARK: - Google Drive

    private var driveContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(drive.isConnected
                     ? "Yalnızca seçtiğiniz klasör ve alt klasörleri taranır."
                     : "Bağlanmak için önce istemci bilgilerini girin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if drive.isBusy { ProgressView().controlSize(.small) }
                if drive.isConnected {
                    Button("Yenile") { Task { await drive.sync(library: library) } }
                        .disabled(drive.isBusy || settings.driveFolderID.isEmpty)
                    Button("Çıkış") { Task { await drive.disconnect(library: library) } }
                } else {
                    Button("Bağlan") { Task { await drive.connect(library: library) } }
                        .disabled(settings.googleClientID.isEmpty || drive.isBusy)
                }
            }
            .controlSize(.small)

            if drive.isConnected {
                SettingsRow(
                    symbol: settings.driveFolderID.isEmpty ? "questionmark.folder" : "folder.fill",
                    symbolColor: settings.driveFolderID.isEmpty ? .orange : .accentColor,
                    title: settings.driveFolderID.isEmpty ? "Klasör seçilmedi" : settings.driveFolderName,
                    detail: settings.driveFolderID.isEmpty
                        ? "Tüm Drive taranmaz; bir klasör seçin."
                        : "\(drive.accountFileCount) video"
                ) {
                    Button(settings.driveFolderID.isEmpty ? "Klasör Seç…" : "Değiştir") {
                        showDrivePicker = true
                    }
                    .controlSize(.small)
                }
            }

            DisclosureGroup("İstemci bilgileri", isExpanded: $showDriveCredentials) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google Cloud Console → Kimlik Bilgileri → OAuth istemci kimliği "
                         + "→ tür: Masaüstü uygulaması.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Client ID", text: $settings.googleClientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $settings.googleClientSecret)
                        .textFieldStyle(.roundedBorder)
                    Text("Yalnızca okuma izni istenir. Yenileme jetonu Anahtar Zinciri'nde saklanır.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))

            if !drive.statusMessage.isEmpty {
                Text(drive.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Subtitles

    private var subtitleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Değişiklikler anında uygulanır, oynatırken de.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Sıfırla") { settings.subtitleStyle = SubtitleStyle() }
                    .controlSize(.small)
            }

            SubtitlePreview(style: settings.subtitleStyle)

            SettingsGroupLabel(text: "Altyazı Çevirisi")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Çeviri Motoru")
                    Picker("", selection: $settings.translationEngine) {
                        ForEach(TranslationEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }

                if settings.translationEngine == .zai {
                    GridRow {
                        Text("Z.ai API Key")
                        SecureField("Z.ai API Key", text: $settings.zaiApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                } else if settings.translationEngine == .openRouter {
                    GridRow {
                        Text("OpenRouter API Key")
                        SecureField("OpenRouter API Key", text: $settings.openRouterApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                    GridRow {
                        Text("Model")
                        Picker("", selection: $settings.openRouterModel) {
                            Text("Otomatik (en iyisinden başla)")
                                .tag(OpenRouterTranslator.automaticModel)
                            Divider()
                            ForEach(OpenRouterTranslator.freeModels, id: \.id) { model in
                                Text(model.title).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }

                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Text(settings.translationEngine.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                }

                GridRow {
                    Text("Altyazı Belleği")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button("Altyazı Belleğini Temizle") {
                                let removed = TranslatedSubtitleCache.clear()
                                SubtitleMemory.clear()
                                translationCacheStats = TranslatedSubtitleCache.stats()
                                rememberedVideoCount = SubtitleMemory.rememberedVideoCount
                                cacheClearedNote = removed > 0
                                    ? "\(removed) çeviri ve tüm altyazı kayıtları silindi."
                                    : "Altyazı kayıtları temizlendi."
                            }
                            .controlSize(.small)
                            .disabled(translationCacheStats.isEmpty && rememberedVideoCount == 0)

                            if let note = cacheClearedNote {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(subtitleMemorySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 6)
            .onAppear {
                translationCacheStats = TranslatedSubtitleCache.stats()
                rememberedVideoCount = SubtitleMemory.rememberedVideoCount
            }

            SettingsGroupLabel(text: "Yazı")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Yazı tipi")
                    Picker("", selection: $settings.subtitleStyle.fontName) {
                        ForEach(SubtitleStyle.availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Boyut")
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(settings.subtitleStyle.fontSize) },
                                set: { settings.subtitleStyle.fontSize = Int($0) }
                            ),
                            in: 16...120, step: 1
                        )
                        Text("\(settings.subtitleStyle.fontSize)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28)
                    }
                }
                GridRow {
                    Text("Stil")
                    HStack(spacing: 14) {
                        Toggle("Kalın", isOn: $settings.subtitleStyle.isBold)
                        Toggle("İtalik", isOn: $settings.subtitleStyle.isItalic)
                    }
                }
            }

            Divider().opacity(0.5)

            SettingsGroupLabel(text: "Renk ve Kenarlık")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Renk")
                    HStack(spacing: 14) {
                        ColorPicker("Yazı", selection: Binding(
                            get: { Color(hex: settings.subtitleStyle.textColor) },
                            set: { settings.subtitleStyle.textColor = $0.hexString }
                        ))
                        .labelsHidden()
                        Text("Yazı").font(.caption).foregroundStyle(.secondary)

                        ColorPicker("Kenarlık", selection: Binding(
                            get: { Color(hex: settings.subtitleStyle.borderColor) },
                            set: { settings.subtitleStyle.borderColor = $0.hexString }
                        ))
                        .labelsHidden()
                        Text("Kenarlık").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Kenarlık kalınlığı")
                    Slider(value: $settings.subtitleStyle.borderSize, in: 0...6, step: 0.5)
                }
                GridRow {
                    Text("Gölge")
                    Slider(value: $settings.subtitleStyle.shadowOffset, in: 0...6, step: 0.5)
                }
                GridRow {
                    Text("Arka plan")
                    Slider(value: $settings.subtitleStyle.backgroundOpacity, in: 0...1, step: 0.05)
                }
            }

            Divider().opacity(0.5)

            SettingsGroupLabel(text: "Konum ve Senkron")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Dikey konum")
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(settings.subtitleStyle.position) },
                                set: { settings.subtitleStyle.position = Int($0) }
                            ),
                            in: 0...100, step: 1
                        )
                        Text("\(settings.subtitleStyle.position)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28)
                    }
                }
                GridRow {
                    Text("Varsayılan gecikme")
                    HStack {
                        Slider(value: $settings.subtitleStyle.delay, in: -10...10, step: 0.1)
                        Text(String(format: "%.1f sn", settings.subtitleStyle.delay))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 52)
                    }
                }
            }

            Text("Tek bir dosya için senkron, oynatıcıdaki altyazı menüsünden "
                 + "“Senkron Ayarı” ile ayarlanır (z / x / c tuşları).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - OpenSubtitles

    private var openSubtitlesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ücretsiz kaynaklar Stremio eklenti protokolünü konuşur — hesap ya da "
                 + "anahtar istemez. Sırayla denenir, biri yanıt vermezse diğerine geçilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(settings.subtitleAddons.enumerated()), id: \.element.id) { index, addon in
                SettingsRow(
                    symbol: addon.isEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                    symbolColor: addon.isEnabled ? .accentColor : .secondary,
                    title: addon.name,
                    detail: addon.host
                ) {
                    HStack(spacing: 8) {
                        Button {
                            move(from: index, to: index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        .help("Yukarı taşı")

                        Button {
                            move(from: index, to: index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == settings.subtitleAddons.count - 1)
                        .help("Aşağı taşı")

                        Toggle("", isOn: Binding(
                            get: { addon.isEnabled },
                            set: { newValue in
                                guard let position = settings.subtitleAddons
                                    .firstIndex(where: { $0.id == addon.id }) else { return }
                                settings.subtitleAddons[position].isEnabled = newValue
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()

                        Button {
                            settings.subtitleAddons.removeAll { $0.id == addon.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Kaldır")
                    }
                }
            }

            if settings.subtitleAddons.isEmpty {
                Text("Kaynak yok. Aşağıdan ekleyin ya da varsayılanı geri getirin.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Eklenti adresi veya manifest.json", text: $newAddonURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await addAddon() } }
                if isProbingAddon { ProgressView().controlSize(.small) }
                Button("Ekle") { Task { await addAddon() } }
                    .disabled(newAddonURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || isProbingAddon)
                Button("Varsayılan") {
                    guard !settings.subtitleAddons.contains(where: {
                        $0.baseURL == SubtitleAddon.builtIn.baseURL
                    }) else { return }
                    settings.subtitleAddons.append(.builtIn)
                }
            }
            .controlSize(.small)

            if !addonMessage.isEmpty {
                Text(addonMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            SettingsGroupLabel(text: "OpenSubtitles Hesabı")
            Text("İsteğe bağlı. TMDB ile eşleşmemiş dosyalarda başlıkla arama için kullanılır.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("API anahtarı").font(.caption).foregroundStyle(.secondary)
                SecureField("Consumer API key", text: $settings.openSubtitlesKey)
                    .textFieldStyle(.roundedBorder)
                Text("opensubtitles.com → hesap açın → Consumer (API) anahtarı alın. Ücretsiz.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsRow(
                symbol: "globe",
                title: "Altyazı dilleri",
                detail: "Virgülle ayırın, örn. tr,en"
            ) {
                TextField("tr,en", text: $settings.openSubtitlesLanguages)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            Link("opensubtitles.com adresini aç",
                 destination: URL(string: "https://www.opensubtitles.com/")!)
                .font(.caption)
        }
    }

    // MARK: - Stream (ZyStream)

    private var streamContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ZyStream, seçtiğiniz akış sitelerinde arama yapıp içeriği doğrudan "
                 + "oynatıcıda açar. Açtığınız kaynaklar sol taraftaki “ZyStream” "
                 + "sekmesinde ve genel arama sonuçlarında görünür.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(settings.streamSources.enumerated()), id: \.element.id) { _, source in
                let info = StreamRegistry.info(id: source.id)
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(
                        symbol: source.isEnabled ? "play.tv.fill" : "play.tv",
                        symbolColor: source.isEnabled ? .accentColor : .secondary,
                        title: info?.displayName ?? source.id,
                        detail: info?.kind.label ?? "Bilinmeyen kaynak"
                    ) {
                        Toggle("", isOn: binding(for: source.id, \.isEnabled))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        Text("Adres").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        TextField("https://…", text: binding(for: source.id, \.baseURL))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        if let info, source.baseURL != info.defaultBaseURL {
                            Button("Varsayılan") {
                                guard let i = settings.streamSources.firstIndex(where: { $0.id == source.id }) else { return }
                                settings.streamSources[i].baseURL = info.defaultBaseURL
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.leading, 31)

                    if !source.nextBaseURL.isEmpty {
                        Text("Sitenin duyurduğu sonraki adres: \(source.nextBaseURL) — bu adres kapandığında oraya geçilecek.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 31)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Button("Adresleri Şimdi Denetle") {
                    isCheckingDomains = true
                    domainCheckNote = nil
                    Task {
                        let moved = await StreamDomainTracker.refreshAll(settings: settings)
                        isCheckingDomains = false
                        domainCheckNote = moved.isEmpty
                            ? "Adresler güncel."
                            : "Güncellendi: \(moved.joined(separator: ", "))"
                    }
                }
                .controlSize(.small)
                .disabled(isCheckingDomains)

                if isCheckingDomains {
                    ProgressView().controlSize(.small)
                } else if let note = domainCheckNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Adresler uygulama açılışında ve ZyStream sekmesine her girişte kendiliğinden "
                 + "denetlenir: site taşındığında ana sayfasında duyurduğu yeni adrese geçilir, "
                 + "elle güncellemeniz gerekmez. Yukarıdaki alandan yine de kendiniz "
                 + "değiştirebilirsiniz. Not: Bu siteler telif korumalı içerik barındırabilir ve "
                 + "yapıları sık değiştiği için zaman zaman çalışmayabilir.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - YouTube

    private var youtubeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow(
                symbol: settings.youtubeSearchEnabled ? "play.rectangle.fill" : "play.rectangle",
                symbolColor: settings.youtubeSearchEnabled ? .red : .secondary,
                title: "Arama sonuçlarında YouTube",
                detail: "Aramaya “YouTube’da Bulunanlar” bölümü eklenir"
            ) {
                Toggle("", isOn: $settings.youtubeSearchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Text("Bazı diziler ve filmler resmi kanallarda tam olarak yayınlanıyor "
                 + "(örneğin “Kurtlar Vadisi”). Bu bölüm sadece arama yaparken çıkar; "
                 + "ana ekranda ve diğer sayfalarda YouTube'a hiç istek gitmez. "
                 + "Klip ve fragmanlar elenir: 4 dakikadan kısa videolar listelenmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !YouTubePlaybackCheck.isToolInstalled {
                Text("Oynatma için yt-dlp gerekiyor: Terminal'de `brew install yt-dlp` "
                     + "çalıştırın. Arama listelemesi yt-dlp olmadan da çalışır, ama "
                     + "video açılmaz.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A binding into one stream source's field, matched by id so a reorder can't
    /// write to the wrong row.
    private func binding<T>(for id: String,
                            _ keyPath: WritableKeyPath<StreamSourceToggle, T>) -> Binding<T> {
        Binding(
            get: { settings.streamSources.first { $0.id == id }?[keyPath: keyPath]
                    ?? StreamRegistry.defaultToggles.first { $0.id == id }![keyPath: keyPath] },
            set: { newValue in
                guard let i = settings.streamSources.firstIndex(where: { $0.id == id }) else { return }
                settings.streamSources[i][keyPath: keyPath] = newValue
            }
        )
    }

    // MARK: - Downloads

    private var downloadsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !torrents.isEngineAvailable {
                Text("aria2 kurulu değil: Terminal'de `brew install aria2` çalıştırın.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsRow(
                symbol: "folder",
                title: "Hedef klasör",
                detail: settings.downloadDirectory
            ) {
                Button("Değiştir") { chooseDownloadDirectory() }
                    .controlSize(.small)
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Torrent adresi")
                    .font(.system(size: 12, weight: .medium))
                TextField(TorrentioClient.defaultBase, text: $settings.torrentAPIBase)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                HStack(spacing: 8) {
                    Text("Film ve dizilerdeki “Torrent’ten Oynat” listesi buradan gelir. Stremio akış eklentisi protokolünü konuşan başka bir adres de yazabilirsiniz; boş bırakırsanız varsayılana döner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Varsayılan") { settings.torrentAPIBase = TorrentioClient.defaultBase }
                        .controlSize(.small)
                        .disabled(settings.torrentAPIBase == TorrentioClient.defaultBase)
                }

                if let reason = TorrentStreamer.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Akış sırasında inen veri geçici önbelleğe yazılır, uygulamadan çıkınca silinir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Torrent devam kayıtları")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Button("Devam Kayıtlarını Temizle") {
                        let removed = resume?.torrentPointCount ?? 0
                        resume?.clearTorrentPoints()
                        torrentResumeClearedNote = removed > 0
                            ? "\(removed) torrent devam kaydı silindi."
                            : "Silinecek kayıt yoktu."
                    }
                    .controlSize(.small)
                    .disabled((resume?.torrentPointCount ?? 0) == 0)

                    if let note = torrentResumeClearedNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("İzlenen torrentler ana ekrandaki “İzlemeyi Sürdür” rafında birikir ve `torrent-resume.json` dosyasında saklanır. Kendiliğinden silinmezler; liste ancak buradan boşaltılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Metadata

    private var metadataContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Poster, özet, oyuncu ve fragmanlar TMDB'den gelir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if library.isFetchingMetadata { ProgressView().controlSize(.small) }
                Button("Bilgileri İndir") {
                    Task { await library.fetchMetadata(settings: settings) }
                }
                .disabled(!settings.hasTMDBToken || library.isFetchingMetadata)
                Button("Tümünü Yenile") {
                    Task { await library.fetchMetadata(settings: settings, force: true) }
                }
                .disabled(!settings.hasTMDBToken || library.isFetchingMetadata)
            }
            .controlSize(.small)

            Picker("Dil", selection: $settings.metadataLanguage) {
                Text("Türkçe").tag("tr-TR")
                Text("English").tag("en-US")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Toggle("Yeni öğeler için bilgileri otomatik indir",
                   isOn: $settings.fetchMetadataAutomatically)

            Toggle("Ana ekranda sinema filmlerinin fragmanını otomatik oynat",
                   isOn: $settings.autoplayTrailers)

            DisclosureGroup("Erişim jetonu", isExpanded: $showTMDBToken) {
                SecureField("TMDB API Read Access Token", text: $settings.tmdbToken)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
            }
            .font(.system(size: 12))

            if !library.metadataMessage.isEmpty {
                Text(library.metadataMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Cache Temizliği")
                    .font(.system(size: 13, weight: .semibold))

                Text("Tüm film ve dizi posterleri ile afişleri yerel diskte saklanır. İndirilen posterler siz temizleyene kadar tekrar yüklenmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Afiş ve Görsel Önbelleği: \(currentImageCacheSize)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button("Cache'i Temizle") {
                        ImageCacheManager.clearAllCaches()
                        currentImageCacheSize = ImageCacheManager.formattedCacheSize
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Subtitle sources

    private func move(from index: Int, to destination: Int) {
        guard settings.subtitleAddons.indices.contains(index),
              settings.subtitleAddons.indices.contains(destination) else { return }
        settings.subtitleAddons.swapAt(index, destination)
    }

    /// Validates the address before storing it, so a typo fails here rather than
    /// silently returning no subtitles later.
    private func addAddon() async {
        let raw = newAddonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isProbingAddon = true
        defer { isProbingAddon = false }

        do {
            let addon = try await StremioSubtitleClient.probe(baseURL: raw)
            guard !settings.subtitleAddons.contains(where: { $0.baseURL == addon.baseURL }) else {
                addonMessage = "Bu kaynak zaten ekli."
                return
            }
            settings.subtitleAddons.append(addon)
            newAddonURL = ""
            addonMessage = "\(addon.name) eklendi."
        } catch {
            addonMessage = error.localizedDescription
        }
    }

    // MARK: - Pickers

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Ekle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.addFolder(url)
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Seç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.downloadDirectory = url.path
    }
}
