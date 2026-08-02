import SwiftUI

struct ZyMovieDetailView: View {
    let hit: ZyMovieHit
    let library: LibraryStore
    let store: ZyMovieStore
    let torrents: TorrentStore
    let streamer: TorrentStreamer
    let player: PlayerModel
    let onBack: () -> Void
    var onOpenRemoteTitle: (RemoteTitle) -> Void = { _ in }
    
    @State private var files: [ZyMovieTorrentFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var playingIndex: Int?
    @State private var isTMDBOnlyHit = false
    
    @FocusState private var isListFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding()
                
                Spacer()
                
                let isFav = store.isFavorite(hit)
                Button(action: {
                    store.toggleFavorite(hit)
                }) {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .foregroundColor(isFav ? .yellow : .secondary)
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding()
            }
            .background(.ultraThinMaterial)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 20) {
                        if let posterURL = hit.remoteTitle?.posterURL {
                            CachedAsyncImage(url: posterURL) { image in
                                image.resizable().aspectRatio(contentMode: .fit)
                            } placeholder: {
                                Color.gray.opacity(0.3)
                            }
                            .frame(width: 200, height: 300)
                            .cornerRadius(12)
                            .shadow(radius: 10)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 200, height: 300)
                                .cornerRadius(12)
                                .overlay(Image(systemName: "film").font(.largeTitle).foregroundColor(.gray))
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text(hit.remoteTitle?.title ?? hit.rssTitle)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                            
                            if let year = hit.remoteTitle?.year {
                                Text(String(year))
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(hit.rssDescription)
                                .font(.body)
                                .padding(.top, 10)
                        }
                        Spacer()
                    }
                    
                    Divider().padding(.vertical)
                    
                    Text("İçerik Dosyaları")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if isLoading {
                        ProgressView("Torrent dosyası analiz ediliyor...")
                            .padding()
                    } else if isTMDBOnlyHit || (errorMessage != nil && hit.remoteTitle != nil) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TurkTorrent Akış Bilgisi")
                                        .font(.headline)
                                    Text("Bu içerik TurkTorrent'in son yüklenen 20 torrent listesinde bulunmuyor. Tüm sezon, bölüm ve alternatif akış kaynaklarında hemen izleyebilirsiniz.")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if let remote = hit.remoteTitle {
                                Button {
                                    onOpenRemoteTitle(remote)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.tv.fill")
                                        Text("Akış & Tüm Kaynaklarda Aç")
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(16)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.3), lineWidth: 1))
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .padding()
                    } else if files.isEmpty {
                        Text("Oynatılabilir video dosyası bulunamadı.")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(files) { file in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(file.name)
                                            .font(.body)
                                        Text(formatBytes(file.size))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    
                                    Button(action: {
                                        playFile(fileIndex: file.index)
                                    }) {
                                        HStack {
                                            if playingIndex == file.index && streamer.isBusy {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                Text("Hemen Oynat")
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .focusable(true)
                                    .disabled(playingIndex != nil && streamer.isBusy)
                                    
                                    Button("İndir") {
                                        Task {
                                            await torrents.add(hit.rssLink, library: library)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .focusable(true)
                                }
                                .padding(10)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        .focused($isListFocused)
                    }
                }
                .padding(30)
            }
        }
        .task {
            await fetchAndParseTorrent()
        }
        .onAppear {
            isListFocused = true
        }
    }
    
    private func playFile(fileIndex: Int?) {
        playingIndex = fileIndex
        store.playingHit = hit
        store.playingFiles = files
        
        let title = hit.remoteTitle?.title ?? hit.rssTitle
        let option = TorrentOption(
            id: hit.rssLink,
            quality: "RSS",
            detail: "TurkTorrent",
            seeds: 0,
            peers: 0,
            provider: "TurkTorrent",
            link: hit.rssLink,
            fileIndex: fileIndex
        )
        // Kararlı kimlik: yerel akış adresi her oynatmada değişiyor, altyazı
        // seçimi ona bağlanırsa bir sonraki açılışta hatırlanmaz.
        let key = "zymovie:\(hit.rssLink)#\(fileIndex.map(String.init) ?? "0")"
        streamer.start(option, title: title) { url, _ in
            player.open(url, title: title, resumeAt: 0, resumeKey: key)
        }
    }
    
    private func fetchAndParseTorrent() async {
        // 1. If cachedFiles already exist (e.g. from persistent favorite cache), load immediately!
        if let cached = hit.cachedFiles, !cached.isEmpty {
            self.files = cached
            return
        }
        
        if !hit.rssLink.hasPrefix("http") {
            // Check if store.hits or store.favorites has a matching RSS hit with http link
            if let matchingRssHit = (store.hits + store.favorites).first(where: {
                $0.rssLink.hasPrefix("http") && (
                    $0.remoteTitle?.id == hit.remoteTitle?.id ||
                    $0.rssTitle.localizedCaseInsensitiveContains(hit.remoteTitle?.title ?? hit.rssTitle)
                )
            }), let matchedURL = URL(string: matchingRssHit.rssLink) {
                await parseTorrentData(from: matchedURL)
                return
            } else {
                isTMDBOnlyHit = true
                return
            }
        }
        
        guard let url = URL(string: hit.rssLink) else {
            isTMDBOnlyHit = true
            return
        }
        await parseTorrentData(from: url)
    }

    private func parseTorrentData(from url: URL) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let dict = BencodeParser.parse(data: data),
                  case .dictionary(let infoDict)? = dict["info"] else {
                errorMessage = "Geçersiz torrent dosyası."
                return
            }
            
            var videoFiles: [ZyMovieTorrentFile] = []
            
            if case .list(let filesList) = infoDict["files"] {
                for (index, fileVal) in filesList.enumerated() {
                    if case .dictionary(let fDict) = fileVal,
                       case .list(let pathList) = fDict["path"],
                       case .integer(let length) = fDict["length"] {
                        
                        let pathStrs = pathList.compactMap { val -> String? in
                            if case .string(let s) = val { return s }
                            return nil
                        }
                        let path = pathStrs.joined(separator: "/")
                        
                        if isVideoFile(path) {
                            videoFiles.append(ZyMovieTorrentFile(index: index, name: path, size: length))
                        }
                    }
                }
            } else if case .string(let name) = infoDict["name"],
                      case .integer(let length) = infoDict["length"] {
                if isVideoFile(name) {
                    videoFiles.append(ZyMovieTorrentFile(index: 0, name: name, size: length))
                }
            }
            
            self.files = videoFiles
            // Cache files persistently if item is in favorites
            store.updateFavoriteTorrentFiles(for: hit, files: videoFiles)
        } catch {
            if hit.remoteTitle != nil {
                isTMDBOnlyHit = true
            } else {
                errorMessage = "Torrent indirilemedi: \(error.localizedDescription)"
            }
        }
    }
    
    private func isVideoFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        let exts = [".mp4", ".mkv", ".avi", ".m4v", ".mov", ".ts", ".m2ts", ".flv", ".wmv", ".mpg", ".mpeg"]
        return exts.contains { lower.hasSuffix($0) }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
