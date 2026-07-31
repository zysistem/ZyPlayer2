import SwiftUI

/// What is being re-matched.
enum MatchTarget {
    case movie(MediaItem)
    case series(key: String, name: String)

    var initialQuery: String {
        switch self {
        case .movie(let item): item.title
        case .series(_, let name): name
        }
    }

    var isMovie: Bool {
        if case .movie = self { return true }
        return false
    }
}

/// One TMDB candidate, flattened from either a movie or a TV result.
private struct Candidate: Identifiable {
    var id: Int
    var title: String
    var year: Int?
    var overview: String?
    var posterPath: String?
}

/// "Bilgileri Düzenle": search TMDB and pick the correct entry by hand.
///
/// Automatic matching cannot resolve ambiguous titles — a 2025 Turkish "Asylum"
/// loses to the 1996 show of the same name — so the fix is to let the user choose.
struct MatchPickerView: View {
    let target: MatchTarget
    let library: LibraryStore
    @Bindable var settings: AppSettings
    let onDone: () -> Void

    @State private var query: String = ""
    @State private var candidates: [Candidate] = []
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .onAppear {
            query = target.initialQuery
            Task { await search() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bilgileri Düzenle")
                .font(.headline)
            Text(target.isMovie ? "Film ara" : "Dizi ara")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Başlık", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Ara") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            Text(message.isEmpty ? "Sonuç yok." : message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        CandidateRow(candidate: candidate) {
                            Task { await apply(candidate) }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if isApplying {
                ProgressView().controlSize(.small)
                Text("Uygulanıyor…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Kapat", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.hasTMDBToken else {
            message = settings.hasTMDBToken ? "" : "TMDB jetonu girilmemiş."
            return
        }
        isSearching = true
        defer { isSearching = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        do {
            if target.isMovie {
                let results = try await client.searchMovie(title: trimmed, year: nil)
                candidates = results.map {
                    Candidate(id: $0.id, title: $0.title, year: $0.year,
                              overview: $0.overview, posterPath: $0.posterPath)
                }
            } else {
                let results = try await client.searchTV(name: trimmed)
                candidates = results.map {
                    Candidate(id: $0.id, title: $0.name, year: $0.year,
                              overview: $0.overview, posterPath: $0.posterPath)
                }
            }
            message = candidates.isEmpty ? "Sonuç yok." : ""
        } catch {
            candidates = []
            message = error.localizedDescription
        }
    }

    private func apply(_ candidate: Candidate) async {
        isApplying = true
        defer { isApplying = false }

        switch target {
        case .movie(let item):
            await library.applyMovieMatch(to: item, tmdbID: candidate.id, settings: settings)
        case .series(let key, _):
            await library.applySeriesMatch(seriesKey: key, tmdbID: candidate.id, settings: settings)
        }
        onDone()
    }
}

private struct CandidateRow: View {
    let candidate: Candidate
    let onPick: () -> Void

    @State private var poster: NSImage?

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if let poster {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(white: 0.18))
                        Image(systemName: "film").foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(candidate.title).fontWeight(.medium)
                        if let year = candidate.year {
                            Text(String(year)).foregroundStyle(.secondary)
                        }
                    }
                    if let overview = candidate.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            guard let path = candidate.posterPath else { return }
            let url = TMDBClient.imageURL(path: path, size: "w154")
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                poster = NSImage(data: data)
            }
        }
    }
}
