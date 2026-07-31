import SwiftUI
import Observation

/// What to look up: a whole film, or one episode of a show. Both are addressed
/// by IMDb id — that is the only key the index understands.
enum TorrentRequest: Hashable {
    case movie(imdbID: String?)
    case episode(imdbID: String, season: Int, episode: Int)

    var key: String {
        switch self {
        case .movie(let imdbID): "movie-\(imdbID ?? "?")"
        case .episode(let imdbID, let season, let episode): "tv-\(imdbID)-\(season)-\(episode)"
        }
    }
}

/// Loads the torrent list for one request. Kept out of the view so a redraw does
/// not re-query the index.
@Observable
final class TorrentPickerModel {
    private(set) var torrents: [TorrentOption] = []
    private(set) var isLoading = false
    private(set) var message: String?
    @ObservationIgnored private var loadedKey: String?

    @MainActor
    func load(_ request: TorrentRequest, settings: AppSettings) async {
        guard loadedKey != request.key else { return }
        loadedKey = request.key
        isLoading = true
        message = nil
        defer { isLoading = false }

        let client = TorrentioClient(base: settings.effectiveTorrentAPIBase)
        do {
            switch request {
            case .movie(let imdbID):
                guard let imdbID, !imdbID.isEmpty else {
                    message = "Bu film için IMDb kimliği bulunamadı, torrent aranamıyor."
                    torrents = []
                    return
                }
                torrents = try await client.streams(imdbID: imdbID, season: nil, episode: nil)

            case .episode(let imdbID, let season, let episode):
                torrents = try await client.streams(
                    imdbID: imdbID, season: season, episode: episode
                )
            }
            if torrents.isEmpty { message = "Torrent bulunamadı." }
        } catch {
            torrents = []
            message = error.localizedDescription
        }
    }
}

/// "Torrent'ten Oynat": what the index has for this title, with the size of each
/// swarm, and a live buffer readout for the one being streamed.
struct TorrentPickerView: View {
    let request: TorrentRequest
    /// False while the IMDb id is still being resolved; the list waits for it
    /// rather than running a fuzzy search that is about to be replaced.
    var isReady: Bool = true
    var showsHeader: Bool = true
    let settings: AppSettings
    let streamer: TorrentStreamer
    let onPlay: (TorrentOption) -> Void
    /// Hands the release off to the download engine. Optional so callers that
    /// only stream (nothing does today) can omit it.
    var onDownload: ((TorrentOption) -> Void)?

    @State private var model = TorrentPickerModel()
    /// Which quality bucket the list is filtered to; nil shows everything.
    @State private var qualityFilter: String?

    /// The buckets present in the results, best first — the selectbox lists these.
    private var availableQualities: [String] {
        var seen = Set<String>()
        return model.torrents
            .sorted { $0.qualityRank < $1.qualityRank }
            .compactMap { seen.insert($0.qualityBucket).inserted ? $0.qualityBucket : nil }
    }

    /// The rows to show, narrowed to the chosen quality.
    private var visibleTorrents: [TorrentOption] {
        guard let qualityFilter else { return model.torrents }
        return model.torrents.filter { $0.qualityBucket == qualityFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.left.arrow.up.right.circle")
                        .foregroundStyle(.secondary)
                    Text("Torrent’ten Oynat")
                        .font(.system(size: 15, weight: .semibold))
                    if model.isLoading || !isReady {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    qualityPicker
                }
            } else {
                HStack(spacing: 8) {
                    if model.isLoading || !isReady {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    qualityPicker
                }
            }

            if let reason = TorrentStreamer.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let message = model.message, model.torrents.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleTorrents) { torrent in
                row(torrent)
            }

            if showsHeader, !model.torrents.isEmpty {
                Text("Akış sırasında indirilen veri önbelleğe alınır ve uygulamadan çıkınca silinir. İndir ile seçtiğiniz klasöre kaydedilir.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(isReady)-\(request.key)") {
            guard isReady else { return }
            await model.load(request, settings: settings)
        }
    }

    /// A frosted dropdown that filters the list by quality — only shown once the
    /// results actually span more than one bucket.
    @ViewBuilder
    private var qualityPicker: some View {
        if availableQualities.count > 1 {
            Menu {
                Button {
                    qualityFilter = nil
                } label: {
                    Label("Tümü", systemImage: qualityFilter == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(availableQualities, id: \.self) { quality in
                    Button {
                        qualityFilter = quality
                    } label: {
                        Label(quality, systemImage: qualityFilter == quality ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                    Text(qualityFilter ?? "Kalite")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .onChange(of: availableQualities) { _, qualities in
                // A quality that vanished after a reload must not leave the list
                // silently empty.
                if let qualityFilter, !qualities.contains(qualityFilter) {
                    self.qualityFilter = nil
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ torrent: TorrentOption) -> some View {
        let isActive = streamer.activeHash == torrent.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    onPlay(torrent)
                } label: {
                    Label(torrent.label, systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!TorrentStreamer.isAvailable || (streamer.isBusy && !isActive))

                if let onDownload {
                    Button {
                        onDownload(torrent)
                    } label: {
                        Label("İndir", systemImage: "arrow.down.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Seçtiğiniz klasöre indir")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(torrent.detail)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(seedColor(torrent.seeds))
                            .frame(width: 6, height: 6)
                        Text(swarmLine(torrent))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if isActive {
                    Button("Durdur") { streamer.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if isActive, streamer.isBusy {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: streamer.bufferProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                    Text(streamer.statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if isActive, case .failed(let error) = streamer.phase {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    private func swarmLine(_ torrent: TorrentOption) -> String {
        var parts = ["\(torrent.seeds) seed"]
        // Only YTS reports leechers; the addon protocol has no field for them.
        if torrent.peers > 0 { parts.append("\(torrent.peers) peer") }
        if let provider = torrent.provider, !provider.isEmpty { parts.append(provider) }
        return parts.joined(separator: " · ")
    }

    /// A swarm with nobody in it will never start; say so before the click.
    private func seedColor(_ seeds: Int) -> Color {
        switch seeds {
        case 0: .red
        case 1..<10: .orange
        default: .green
        }
    }
}
