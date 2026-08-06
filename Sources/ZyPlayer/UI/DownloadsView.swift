import SwiftUI
import UniformTypeIdentifiers

/// Torrent downloads: add, track, pause, remove.
struct DownloadsView: View {
    let library: LibraryStore
    let torrents: TorrentStore
    let streamer: TorrentStreamer
    @Bindable var settings: AppSettings
    /// Bir magnet/torrent adresini diske hiç yazmadan oynatıcıya açar.
    let onPlay: (String) -> Void

    @State private var linkInput = ""

    // Bu ekran yalnızca gerçek indirmeleri gösterir. İzlenen torrentlerin
    // devam noktaları ana ekrandaki "İzlemeyi Sürdür" rafına ait; burada da
    // durunca indirme listesi hiç indirilmemiş içerikle karışıyordu.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !torrents.isEngineAvailable {
                missingEngine
            } else if torrents.downloads.isEmpty {
                empty
            } else {
                list
            }
        }
        .task {
            await torrents.startIfNeeded()
            torrents.beginPolling(library: library)
        }
        .onDisappear { torrents.endPolling() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Magnet bağlantısı ya da .torrent adresi", text: $linkInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addLink() }

                Button("Ekle") { addLink() }
                    .disabled(linkInput.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Oynat") { playLink() }
                    .disabled(linkInput.trimmingCharacters(in: .whitespaces).isEmpty || streamer.isBusy)

                Button(".torrent Aç…") { chooseTorrentFile() }
            }

            if streamer.isBusy {
                HStack(spacing: 8) {
                    ProgressView(value: streamer.phase == .connecting ? nil : streamer.bufferProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text(streamer.statusLine.isEmpty ? "Bağlanılıyor…" : streamer.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Durdur") { streamer.stop() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else if case .failed(let message) = streamer.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(settings.downloadDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Değiştir") { chooseDirectory() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                if torrents.isStarting { ProgressView().controlSize(.small) }
            }

            if !torrents.statusMessage.isEmpty {
                Text(torrents.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(torrents.downloads) { download in
                    DownloadRow(download: download, torrents: torrents, library: library)
                    Divider()
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("İndirme yok").font(.title3.weight(.semibold))
            Text("Magnet bağlantısı yapıştırın ya da bir .torrent dosyasını buraya sürükleyin.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingEngine: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("İndirme motoru bulunamadı").font(.title3.weight(.semibold))
            Text("Terminal'de `brew install aria2` çalıştırıp ZyPlayer'ı yeniden başlatın.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addLink() {
        let value = linkInput
        linkInput = ""
        Task { await torrents.add(value, library: library) }
    }

    private func playLink() {
        let value = linkInput
        linkInput = ""
        onPlay(value)
    }

    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await torrents.addTorrentFile(url, library: library) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Seç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.downloadDirectory = url.path
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "torrent" else { return }
            Task { await torrents.addTorrentFile(url, library: library) }
        }
        return true
    }
}

private struct DownloadRow: View {
    let download: TorrentDownload
    let torrents: TorrentStore
    let library: LibraryStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 6) {
                Text(download.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProgressView(value: download.progress)
                    .progressViewStyle(.linear)

                HStack(spacing: 10) {
                    Text(download.sizeLine)
                    if !download.speedLine.isEmpty {
                        Text("↓ \(download.speedLine)")
                    }
                    if let eta = download.etaLine {
                        Text("kalan \(eta)")
                    }
                    if download.connections > 0 {
                        Text("\(download.connections) eş")
                    }
                    if let error = download.errorMessage, !error.isEmpty {
                        Text(error).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if download.isActive {
                    Button { Task { await torrents.pause(download) } } label: {
                        Image(systemName: "pause.fill")
                    }
                    .help("Duraklat")
                } else if download.status == "paused" || download.status == "waiting" {
                    Button { Task { await torrents.resume(download) } } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Devam et")
                }

                Menu {
                    Button("Listeden Kaldır") {
                        Task { await torrents.remove(download, deleteFiles: false, library: library) }
                    }
                    Button("Kaldır ve Dosyaları Sil", role: .destructive) {
                        Task { await torrents.remove(download, deleteFiles: true, library: library) }
                    }
                    if let first = download.filePaths.first {
                        Divider()
                        Button("Finder'da Göster") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch download.status {
        case "complete": "checkmark.circle.fill"
        case "error": "exclamationmark.circle.fill"
        case "paused": "pause.circle.fill"
        default: "arrow.down.circle"
        }
    }

    private var iconColor: Color {
        switch download.status {
        case "complete": .green
        case "error": .red
        case "paused": .secondary
        default: .accentColor
        }
    }
}
