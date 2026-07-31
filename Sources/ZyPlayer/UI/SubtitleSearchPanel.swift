import SwiftUI

/// Finds subtitles for whatever is playing, from either source.
///
/// "Ücretsiz" speaks the Stremio addon protocol and needs no account at all;
/// "Hesabım" is the older opensubtitles.com path, kept because the addon
/// protocol can only look things up by IMDb id — a file TMDB never matched has
/// no other way to be searched.
struct SubtitleSearchPanel: View {
    let model: PlayerModel
    let library: LibraryStore
    @Bindable var settings: AppSettings
    /// The library item being played, if it is in the library at all.
    let item: MediaItem?
    /// Pre-filled from the library item, so the first search is usually right.
    let initialQuery: String
    let season: Int?
    let episode: Int?
    let onDone: () -> Void

    private enum Source: String, CaseIterable, Identifiable {
        case free, account
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: "Ücretsiz"
            case .account: "Hesabım"
            }
        }
    }

    @State private var source: Source = .free

    /// Shared by both tabs: the free one searches by it, the account one uses it
    /// instead of the fuzzy title query.
    @State private var imdbID: String?
    /// Hash of the playing file, so opensubtitles.com can flag the entries that
    /// were timed against exactly this release.
    @State private var fileHash: (hash: String, size: Int64)?

    // Free source
    @State private var freeResults: [StremioSubtitleClient.Result] = []
    @State private var isResolving = true
    @State private var freeMessage = ""
    /// What the user typed here; starts as the playing title.
    @State private var freeQuery = ""
    @State private var freeSeason = ""
    @State private var freeEpisode = ""

    // Account source
    @State private var query = ""
    @State private var results: [OpenSubtitlesClient.Subtitle] = []
    @State private var isSearching = false
    @State private var message = ""

    @State private var downloadingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        // Wide enough that a full release name — the whole point of the list —
        // fits on one line instead of being cut in half.
        .frame(width: 760, height: 580)
        .onAppear {
            query = initialQuery
            freeQuery = initialQuery
            freeSeason = season.map(String.init) ?? ""
            freeEpisode = episode.map(String.init) ?? ""
            // The account source is the only one that reliably knows release
            // names, so it leads whenever there is a key for it.
            source = settings.hasOpenSubtitlesKey ? .account : .free
            Task { await prepare() }
        }
        // A tab the user switches to should already be showing something.
        .onChange(of: source) { _, new in
            switch new {
            case .free where freeResults.isEmpty && imdbID != nil:
                Task { await runFreeSearch() }
            case .account where results.isEmpty && settings.hasOpenSubtitlesKey:
                Task { await search() }
            default:
                break
            }
        }
    }

    /// The playing file's own name, shown so the user can compare it against the
    /// release names in the list — that comparison is the whole decision.
    private var localFileName: String {
        guard let url = item?.url ?? model.currentURL, url.isFileURL else { return "" }
        let name = url.lastPathComponent
        return name.removingPercentEncoding ?? name
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "captions.bubble.fill").foregroundStyle(.tint)
                Text("Altyazı Ara").font(.headline)
                Spacer()
                if let season, let episode {
                    Text("S\(season)B\(episode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !localFileName.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(localFileName)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Oynatılan dosya — altyazı sürümünü buna göre seçin")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source == .free {
                // Searchable by name here too. The protocol only knows IMDb ids,
                // so a typed title is resolved through TMDB first — that is the
                // same lookup the library itself uses.
                HStack(spacing: 8) {
                    TextField("Başlık", text: $freeQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await resolveAndSearch() } }
                    Text("S").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $freeSeason)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 34)
                    Text("B").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $freeEpisode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 34)
                    Button("Ara") { Task { await resolveAndSearch() } }
                        .disabled(freeQuery.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
                }
                .controlSize(.small)

                HStack(spacing: 8) {
                    if let imdbID {
                        Text(imdbID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Diller").font(.caption).foregroundStyle(.secondary)
                    TextField("tr,en", text: $settings.openSubtitlesLanguages)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { Task { await runFreeSearch() } }
                    Button("Yenile") { Task { await runFreeSearch() } }
                        .disabled(imdbID == nil || isResolving)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    TextField("Başlık", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search() } }
                    Button("Ara") { Task { await search() } }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }

                HStack(spacing: 8) {
                    Text("Diller").font(.caption).foregroundStyle(.secondary)
                    TextField("tr,en", text: $settings.openSubtitlesLanguages)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Spacer()
                    if let imdbID {
                        Text(fileHash == nil
                             ? imdbID
                             : "\(imdbID) · dosya imzası gönderildi")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .free:    freeContent
        case .account: accountContent
        }
    }

    // MARK: - Free source

    @ViewBuilder
    private var freeContent: some View {
        if settings.enabledSubtitleAddons.isEmpty {
            notice(symbol: "square.stack.3d.up.slash",
                   title: "Kaynak yok",
                   detail: "Ayarlar → Altyazı Kaynakları'ndan en az bir eklenti etkinleştirin.")
        } else if isResolving {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if imdbID == nil {
            notice(symbol: "questionmark.circle",
                   title: freeMessage.isEmpty ? "Bu dosya eşleşmemiş" : freeMessage,
                   detail: "Ücretsiz kaynaklar IMDb kimliğiyle arama yapar. Yukarıdaki kutuya "
                         + "başlığı yazıp “Ara”ya basın — kimlik TMDB üzerinden bulunur.")
        } else if freeResults.isEmpty {
            notice(symbol: "text.magnifyingglass",
                   title: freeMessage.isEmpty ? "Sonuç yok" : freeMessage,
                   detail: "Dil listesini genişletmeyi deneyin, örn. tr,en.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(freeResults) { result in
                        freeRow(result)
                        Divider()
                    }
                }
            }
        }
    }

    private func freeRow(_ result: StremioSubtitleClient.Result) -> some View {
        Button {
            Task { await downloadFree(result) }
        } label: {
            HStack(spacing: 12) {
                Text(result.language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayName)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(result.releaseName.isEmpty
                         ? "\(result.addonName) · sürüm adı yok"
                         : "\(result.languageName) · \(result.addonName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if downloadingID == result.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    // MARK: - Account source

    @ViewBuilder
    private var accountContent: some View {
        if !settings.hasOpenSubtitlesKey {
            missingKey
        } else if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            Text(message.isEmpty ? "Sonuç yok." : message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { subtitle in
                        row(subtitle)
                        Divider()
                    }
                }
            }
        }
    }

    private var missingKey: some View {
        VStack(spacing: 12) {
            Image(systemName: "key")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("API anahtarı gerekli").font(.headline)
            Text("Bu sekme opensubtitles.com hesabı ister. Anahtarsız arama için "
                 + "“Ücretsiz” sekmesini kullanın.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            SecureField("API anahtarı", text: $settings.openSubtitlesKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(_ subtitle: OpenSubtitlesClient.Subtitle) -> some View {
        Button {
            Task { await download(subtitle) }
        } label: {
            HStack(spacing: 12) {
                Text(subtitle.language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 3) {
                    if subtitle.matchesFile {
                        Label("Dosyanla eşleşiyor", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    // Wrapped, never elided: which release this is for is the
                    // one thing the row exists to say.
                    Text(subtitle.releaseName)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fileName = subtitle.fileName, !fileName.isEmpty {
                        Text(fileName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        Label("\(subtitle.downloadCount)", systemImage: "arrow.down.circle")
                        if let fps = subtitle.fps, fps > 0 {
                            Text(String(format: "%.3f fps", fps))
                        }
                        if subtitle.isHearingImpaired {
                            Label("İşitme engelli", systemImage: "ear")
                        }
                        if let uploader = subtitle.uploader, !uploader.isEmpty {
                            Text(uploader)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if downloadingID == subtitle.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    private func notice(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            if source == .free, !freeResults.isEmpty {
                Text(freeResults.contains { !$0.releaseName.isEmpty }
                     ? "Sürüm adını yalnızca bildiren kaynaklar gösterir; kayma olursa "
                       + "oynatıcıdan z / x ile senkronlayın."
                     : "Bu kaynak sürüm adı bildirmiyor. Sürüm adı ve dosya eşleşmesi için "
                       + "“Hesabım” sekmesini kullanın.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if source == .account, !message.isEmpty, !results.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Kapat", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    /// True while the free tab still points at the file on screen, rather than
    /// something the user typed.
    private var isSearchingPlayingTitle: Bool {
        freeQuery.trimmingCharacters(in: .whitespacesAndNewlines) == initialQuery
            && Int(freeSeason) == season
            && Int(freeEpisode) == episode
    }

    /// One-time setup both tabs depend on: the IMDb id and the file hash.
    private func prepare() async {
        isResolving = true
        if let item {
            imdbID = await library.imdbID(for: item, settings: settings)
            // Hashing reads 128 KB off both ends of the file; off the main
            // actor so the sheet still animates in.
            let url = item.url
            if url.isFileURL {
                fileHash = await Task.detached { OpenSubtitlesHash.compute(for: url) }.value
            }
        }
        isResolving = false

        switch source {
        case .free:
            guard imdbID != nil else { return }
            await runFreeSearch()
        case .account:
            await search()
        }
    }

    /// Turns a typed title into the IMDb id the addon protocol needs, then
    /// searches. TMDB is asked because it is the only name→id map this app has.
    private func resolveAndSearch() async {
        let trimmed = freeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard settings.hasTMDBToken else {
            freeMessage = "Başlıkla aramak için Ayarlar’dan TMDB jetonu girin."
            freeResults = []
            return
        }

        isResolving = true
        defer { isResolving = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let hit = (try? await client.searchMulti(query: trimmed))?
            .compactMap(RemoteTitle.init(multi:))
            .first else {
            freeResults = []
            freeMessage = "‘\(trimmed)’ TMDB’de bulunamadı."
            imdbID = nil
            return
        }

        let resolved: String?
        switch hit.kind {
        case .movie: resolved = try? await client.movieDetail(id: hit.tmdbID).imdbId
        case .tv:    resolved = try? await client.externalIDs(tvID: hit.tmdbID).imdbId
        }
        guard let resolved, !resolved.isEmpty else {
            freeResults = []
            freeMessage = "‘\(hit.title)’ için IMDb kimliği yok."
            imdbID = nil
            return
        }

        imdbID = resolved
        await runFreeSearch()
    }

    private func runFreeSearch() async {
        guard let imdbID else { return }
        isResolving = true
        defer { isResolving = false }

        let client = StremioSubtitleClient(
            addons: settings.subtitleAddons,
            languages: settings.openSubtitlesLanguages
        )
        do {
            freeResults = try await client.search(
                imdbID: imdbID,
                season: Int(freeSeason),
                episode: Int(freeEpisode),
                // Hashing only pays off for the file actually playing: a hash
                // match against someone else's title is worse than no hash.
                videoURL: isSearchingPlayingTitle ? item?.url : nil
            )
            freeMessage = freeResults.isEmpty ? "Sonuç yok" : ""
        } catch {
            freeResults = []
            freeMessage = error.localizedDescription
        }
    }

    private func downloadFree(_ result: StremioSubtitleClient.Result) async {
        downloadingID = result.id
        defer { downloadingID = nil }

        let client = StremioSubtitleClient(
            addons: settings.subtitleAddons,
            languages: settings.openSubtitlesLanguages
        )
        do {
            let file = try await client.download(result)
            model.addSubtitleFile(file)
            onDone()
        } catch {
            freeMessage = error.localizedDescription
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.hasOpenSubtitlesKey else { return }
        isSearching = true
        defer { isSearching = false }

        // The id and the hash describe the file on screen, so they only apply
        // while the query still does too — once the user types another title,
        // that title is what they want searched.
        let isPlayingTitle = trimmed == initialQuery

        let client = OpenSubtitlesClient(
            apiKey: settings.openSubtitlesKey,
            languages: settings.openSubtitlesLanguages
        )
        do {
            results = try await client.search(
                query: trimmed,
                season: season,
                episode: episode,
                imdbID: isPlayingTitle ? imdbID : nil,
                hash: isPlayingTitle ? fileHash : nil
            )
            message = results.isEmpty ? "Sonuç yok." : ""
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    private func download(_ subtitle: OpenSubtitlesClient.Subtitle) async {
        downloadingID = subtitle.id
        defer { downloadingID = nil }

        let client = OpenSubtitlesClient(
            apiKey: settings.openSubtitlesKey,
            languages: settings.openSubtitlesLanguages
        )
        do {
            let file = try await client.download(subtitle)
            model.addSubtitleFile(file)
            onDone()
        } catch {
            message = error.localizedDescription
        }
    }
}
