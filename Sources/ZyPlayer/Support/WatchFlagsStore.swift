import Foundation
import Observation

/// Kütüphane dışı bir kaynağın "İzledim"/"İzleyeceğim" sekmesinde kart olarak
/// çizilebilmesi için sakladığımız en az bilgi. `WatchFlagsStore` yalnızca bir
/// anahtar hatırlarsa (`hit.id` gibi), o kaynağın canlı kataloğu o an yüklü
/// değilse (örn. IPTV oturumu kapalıyken) kartı çizecek hiçbir şey kalmaz —
/// bu yüzden işaretlenirken zaten elde olan nesnenin kendisi saklanıyor.
enum WatchSnapshot: Codable, Hashable {
    case stream(StreamHit)
    case iptv(IPTVFavorite)
    case torrent(ZyMovieHit)
    case remote(RemoteTitle)
}

struct WatchEntry: Codable, Hashable {
    var isFinished = false
    var wantToWatch = false
    var snapshot: WatchSnapshot?
    var updatedAt: Date = Date()
}

/// Kütüphane dışındaki kaynaklar (ZyStream, IPTV, torrent/ZyMovie, Apple
/// TV+/Bollywood'un TMDB kartları) için İzledim/İzleyeceğim durumu.
///
/// Kütüphanenin kendi `LibraryStore.watchStates`'i `MediaItem.id: UUID` ile
/// anahtarlanıyor; bu kaynakların ortak paydası UUID değil — zaten
/// `PlaybackResumeStore`'un kullandığı string anahtar biçimi (`StreamHit.id`,
/// `"iptv:movie:123"`, `ZyMovieHit.rssLink`, `RemoteTitle.id`...).
@Observable
final class WatchFlagsStore {
    static let shared = WatchFlagsStore()

    private let file = LocalStore(fileName: "watch-flags.json", defaultValue: [String: WatchEntry]())
    private(set) var entries: [String: WatchEntry] = [:]

    private init() {
        entries = file.value
    }

    func isFinished(_ key: String) -> Bool { entries[key]?.isFinished ?? false }
    func isWantToWatch(_ key: String) -> Bool { entries[key]?.wantToWatch ?? false }

    /// İzledim işaretlenince izleyecekler listesinden düşer — ikisi birlikte
    /// anlamsız (kart köşesinde de tek rozet gösteriliyor). `snapshot`, kart
    /// bilgisini biliyorsak (kullanıcı bir kartı işaretlediğinde her zaman
    /// öyledir) yazılır/günceller; bilmiyorsak (örn. otomatik işaretleme,
    /// aşağıya bkz.) önceki kayıtlı snapshot korunur.
    func setFinished(_ key: String, _ value: Bool, snapshot: WatchSnapshot? = nil) {
        var entry = entries[key] ?? WatchEntry()
        entry.isFinished = value
        if value { entry.wantToWatch = false }
        if let snapshot { entry.snapshot = snapshot }
        commit(key, entry)
    }

    func setWantToWatch(_ key: String, _ value: Bool, snapshot: WatchSnapshot? = nil) {
        var entry = entries[key] ?? WatchEntry()
        entry.wantToWatch = value
        if value { entry.isFinished = false }
        if let snapshot { entry.snapshot = snapshot }
        commit(key, entry)
    }

    private func commit(_ key: String, _ entry: WatchEntry) {
        var entry = entry
        entry.updatedAt = Date()
        if !entry.isFinished, !entry.wantToWatch {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
        file.replace(with: entries)
    }

    /// "İzledim" sekmesinde göstermek için — en son işaretlenen önce.
    var finishedSnapshots: [(key: String, snapshot: WatchSnapshot)] {
        entries.filter { $0.value.isFinished }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .compactMap { key, entry in entry.snapshot.map { (key, $0) } }
    }

    /// "İzleyeceğim" sekmesi için, aynı sırayla.
    var wantToWatchSnapshots: [(key: String, snapshot: WatchSnapshot)] {
        entries.filter { $0.value.wantToWatch }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .compactMap { key, entry in entry.snapshot.map { (key, $0) } }
    }
}
