import Foundation
import Observation

/// How a resume point is played back again.
/// `youtube` kendi türü: "İzlemeye Devam Et" rafı yalnızca `stream` girdilerini
/// gösteriyor (onları yeniden çözebilmek için sağlayıcı + sayfa adresi gerekiyor),
/// bir YouTube videosu ise arama sonucundan yeniden açıldığında kaldığı yerden
/// devam ediyor.
enum ResumeKind: String, Codable { case stream, torrent, youtube }

/// A "continue where you left off" entry for a source with no library row: a
/// ZyStream title or a streamed torrent. It carries enough to redraw a card and
/// to re-launch playback (a streaming page to re-resolve, or a magnet to re-open).
struct ResumePoint: Codable, Identifiable, Hashable {
    var id: String
    var kind: ResumeKind
    var title: String
    var position: Double = 0
    var duration: Double = 0
    var posterURLString: String?
    // Stream re-launch.
    var providerID: String?
    var pageURL: String?
    // Torrent re-launch.
    var magnet: String?
    var fileIndex: Int?
    /// The subtitle language the user last watched with, re-selected on resume.
    var subtitleLabel: String?
    var updatedAt: Date = Date()

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    /// Near the end counts as watched, so it drops off the continue list.
    /// Also counts as finished if less than 10 minutes (600 seconds) remain.
    var isFinished: Bool {
        let remaining = duration - position
        if duration > 600 {
            return progress >= 0.92 || remaining <= 600
        }
        return progress >= 0.92
    }
    var posterURL: URL? { posterURLString.flatMap { URL(string: $0) } }

    init(id: String, kind: ResumeKind, title: String,
         posterURLString: String? = nil, providerID: String? = nil, pageURL: String? = nil,
         magnet: String? = nil, fileIndex: Int? = nil, subtitleLabel: String? = nil) {
        self.id = id; self.kind = kind; self.title = title
        self.posterURLString = posterURLString
        self.providerID = providerID; self.pageURL = pageURL
        self.magnet = magnet; self.fileIndex = fileIndex
        self.subtitleLabel = subtitleLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        kind = c.value(.kind, ResumeKind.stream)
        title = c.value(.title, "")
        position = c.value(.position, 0)
        duration = c.value(.duration, 0)
        posterURLString = c.optional(.posterURLString)
        providerID = c.optional(.providerID)
        pageURL = c.optional(.pageURL)
        magnet = c.optional(.magnet)
        fileIndex = c.optional(.fileIndex)
        subtitleLabel = c.optional(.subtitleLabel)
        updatedAt = c.value(.updatedAt, Date())
    }
}

struct ResumeData: Codable {
    var points: [ResumePoint] = []
    init(points: [ResumePoint] = []) { self.points = points }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = c.value(.points, [])
    }
}

/// Persisted "continue watching" for streams and torrents, keyed by a stable id
/// (a streaming page URL, or `torrent:<infoHash>`) rather than the ephemeral media
/// URL that actually plays.
@MainActor
@Observable
final class PlaybackResumeStore {
    private(set) var points: [ResumePoint] = []

    @ObservationIgnored private let file = LocalStore(
        fileName: "resume-points.json", defaultValue: ResumeData()
    )
    /// Torrent devam noktaları ayrı bir dosyada durur: İndirmeler ekranından
    /// kaldırıldıkları için biriktikleri tek yer burasıdır ve kullanıcı
    /// "temizle" dediğinde yalnızca bu dosya boşaltılır — ZyStream ve YouTube
    /// devam kayıtları etkilenmez.
    @ObservationIgnored private let torrentFile = LocalStore(
        fileName: "torrent-resume.json", defaultValue: ResumeData()
    )

    init() {
        // Eski sürümlerde her tür tek dosyadaydı; oradaki torrent girdileri
        // silinmez, yeni dosyaya taşınır.
        let shared = file.value.points.filter { $0.kind != .torrent }
        let stranded = file.value.points.filter { $0.kind == .torrent }
        var torrents = torrentFile.value.points
        for point in stranded where !torrents.contains(where: { $0.id == point.id }) {
            torrents.append(point)
        }
        points = shared + torrents
        if !stranded.isEmpty { persist() }
    }

    func point(forKey id: String) -> ResumePoint? { points.first { $0.id == id } }

    /// Saved position for a key, or 0 if none or already finished.
    func position(forKey id: String) -> Double {
        guard let p = point(forKey: id), !p.isFinished else { return 0 }
        return p.position
    }

    /// Registers (or refreshes the metadata of) a point when playback starts,
    /// preserving any existing position.
    func begin(_ point: ResumePoint) {
        var p = point
        if let existing = self.point(forKey: p.id) {
            p.position = existing.position
            p.duration = existing.duration
        }
        p.updatedAt = Date()
        upsert(p)
    }

    /// Updates progress from the player. Ignored for an unknown key. `subtitleLabel`
    /// is stored when non-nil so the choice is remembered for next time.
    func update(key id: String, position: Double, duration: Double, subtitleLabel: String? = nil) {
        guard var p = point(forKey: id) else { return }
        p.position = position
        p.duration = duration
        if let subtitleLabel { p.subtitleLabel = subtitleLabel }
        p.updatedAt = Date()
        upsert(p)
    }

    func remove(key id: String) {
        points.removeAll { $0.id == id }
        persist()
    }

    /// In-progress ZyStream titles, most recent first.
    var streamContinue: [ResumePoint] {
        points.filter { $0.kind == .stream && !$0.isFinished && $0.position > 5 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Saklanan torrent devam kaydı sayısı — Ayarlar'daki temizleme düğmesi
    /// neyi sileceğini söyleyebilsin diye.
    var torrentPointCount: Int { points.count { $0.kind == .torrent } }

    /// Torrent devam kayıtlarının tamamını siler. Kendiliğinden temizlenmezler:
    /// izlenen her torrent burada birikir ve yalnızca kullanıcı boşaltır.
    func clearTorrentPoints() {
        points.removeAll { $0.kind == .torrent }
        persist()
    }

    private func upsert(_ point: ResumePoint) {
        if let index = points.firstIndex(where: { $0.id == point.id }) {
            points[index] = point
        } else {
            points.append(point)
        }
        persist()
    }

    private func persist() {
        file.replace(with: ResumeData(points: points.filter { $0.kind != .torrent }))
        torrentFile.replace(with: ResumeData(points: points.filter { $0.kind == .torrent }))
    }
}
