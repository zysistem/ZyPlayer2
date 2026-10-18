import Foundation
import AppKit
import Observation

// MARK: - Kaynaklar

/// Drive'a senkronlanan bir veri kaynağı: bir `LocalStore` dosyası ya da bir
/// UserDefaults anahtarı.
protocol CloudSyncSource: AnyObject {
    var syncName: String { get }
    /// Yerel değerin JSON'u; yerelde hiç veri yoksa nil.
    func exportForSync() -> Data?
    /// Birleşik JSON'u yerele uygular; çözülemezse false döner ve hiçbir şeye
    /// dokunmaz.
    func importFromSync(_ data: Data) -> Bool
    /// Ana iş parçacığında alınan, JSON'u herhangi bir iş parçacığında
    /// üretebilen anlık görüntü. Senkron, pahalı kodlama ve birleştirme işini
    /// arka planda yapabilsin diye: video kareleri ana iş parçacığında
    /// çiziliyor ve oradaki her uzun iş oynatmada takılma olarak görünüyor.
    func syncSnapshot() -> CloudSyncSnapshot
}

extension CloudSyncSource {
    /// Varsayılan: dışa aktarma zaten iş parçacığı güvenli (UserDefaults, disk).
    func syncSnapshot() -> CloudSyncSnapshot {
        CloudSyncSnapshot { [self] in exportForSync() }
    }
}

/// Bir kaynağın o anki halinden JSON üretir; arka planda çağrılabilir.
struct CloudSyncSnapshot: @unchecked Sendable {
    let makeData: () -> Data?
}

/// LocalStore dışındaki kaynaklar için (ör. ZyMovie favorileri UserDefaults'ta).
final class ClosureSyncSource: CloudSyncSource {
    let syncName: String
    private let export: () -> Data?
    private let apply: (Data) -> Bool

    init(name: String, export: @escaping () -> Data?, apply: @escaping (Data) -> Bool) {
        syncName = name
        self.export = export
        self.apply = apply
    }

    func exportForSync() -> Data? { export() }
    func importFromSync(_ data: Data) -> Bool { apply(data) }
}

/// Senkronlanan verilerin listesi ve canlı kaynakların kaydı.
enum CloudSyncRegistry {
    /// Drive'daki tek JSON'a giren veriler. Önbellekler (IPTV kataloğu, IMDb
    /// puanları, öneriler, çeviriler) ve cihaza bağlı kayıtlar (kütüphane
    /// klasörleri ve yer imleri, SMB paylaşımları, indirmeler) bilerek dışarıda:
    /// başka bir Mac'te anlamları yok, yeniden üretilebilirler.
    static let syncedNames: [String] = [
        "resume-points.json",      // İzlemeye devam et (ZyStream, YouTube, IPTV)
        "torrent-resume.json",     // Torrent devam noktaları
        "watchstate.json",         // Kütüphane izleme ilerlemesi
        "watch-flags.json",        // İzledim / İzleyeceğim
        "remote-favorites.json",   // TMDB favorileri
        "stream-favorites.json",   // ZyStream favorileri
        "iptv-favorites.json",     // IPTV favorileri
        "subtitle-memory.json",    // Hatırlanan altyazı seçimleri
        "skip-markers.json",       // Tanıtım/jenerik sınırları
        "settings.json",           // Ayarlar (cihaza özgü anahtarlar hariç)
        "defaults:zyMovieFavorites" // ZyMovie favorileri (UserDefaults)
    ]

    private final class WeakSource {
        weak var source: CloudSyncSource?
        init(_ source: CloudSyncSource) { self.source = source }
    }

    private static let lock = NSLock()
    private static var sources: [String: WeakSource] = [:]
    /// Her dosyanın yerel değişiklik sayacı. Senkron arka planda birleştirirken
    /// dosya değişirse, birleşim o dosyaya yazılmaz (yeni değişiklik ezilmesin).
    private static var generations: [String: Int] = [:]

    /// Yerel bir değişiklikte ana iş parçacığında çağrılır (CloudSyncStore).
    static var onLocalChange: (() -> Void)?

    /// Video oynarken true (PlayerModel yazar, ana iş parçacığında). Oynatma
    /// sırasında devam noktası 5 saniyede bir yazılıyor; senkron bu sürede
    /// seyrekleşir.
    static var isPlaybackActive = false

    static func generation(of name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generations[name, default: 0]
    }

    /// Aynı ada ikinci kayıt öncekinin yerini alır — `AppSettings` açılışta
    /// iki kez kuruluyor, sonraki asıl kullanılan örnek.
    static func register(_ source: CloudSyncSource) {
        guard syncedNames.contains(source.syncName) else { return }
        lock.lock()
        sources[source.syncName] = WeakSource(source)
        lock.unlock()
    }

    /// Canlı kaynak; hiç kurulmamışsa (tembel `static` depolar) doğrudan diske
    /// ya da UserDefaults'a giden bir yedek kaynak.
    static func source(named name: String) -> CloudSyncSource {
        lock.lock()
        let live = sources[name]?.source
        lock.unlock()
        return live ?? fallbackSource(for: name)
    }

    static func markDirty(_ name: String) {
        guard syncedNames.contains(name) else { return }
        lock.lock()
        generations[name, default: 0] += 1
        lock.unlock()
        DispatchQueue.main.async { onLocalChange?() }
    }

    private static func fallbackSource(for name: String) -> CloudSyncSource {
        if name.hasPrefix("defaults:") {
            let key = String(name.dropFirst("defaults:".count))
            return ClosureSyncSource(
                name: name,
                export: { UserDefaults.standard.data(forKey: key) },
                apply: { data in
                    UserDefaults.standard.set(data, forKey: key)
                    return true
                }
            )
        }
        let url = AppPaths.file(name)
        return ClosureSyncSource(
            name: name,
            export: {
                guard let data = try? Data(contentsOf: url), !data.isEmpty,
                      (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
                return data
            },
            apply: { data in
                (try? data.write(to: url, options: .atomic)) != nil
            }
        )
    }
}

// MARK: - Üç yönlü birleştirme

/// İki cihazın değişikliklerini kaybetmeden birleştirir.
///
/// `base` son başarılı senkrondaki ortak haldir. Bir taraf base'e göre
/// değişmemişse diğer tarafın hali alınır; ikisi de değiştiyse nesneler
/// anahtar anahtar, kayıt dizileri kimlik kimlik birleşir. Silmeler de böyle
/// anlaşılır: base'de olup bir tarafta olmayan, diğer tarafta da dokunulmamış
/// kayıt silinmiştir. base yoksa (ilk senkron) hiçbir şey silinmez, birleşim
/// alınır.
enum JSONMerge {

    static func merge(base: Any?, local: Any?, remote: Any?) -> Any? {
        guard let local else { return remote }
        guard let remote else { return local }
        if same(local, remote) { return local }
        if let base {
            if same(local, base) { return remote }
            if same(remote, base) { return local }
        }
        if let l = local as? [String: Any], let r = remote as? [String: Any] {
            // Zaman damgalı bir kayıt bütün olarak en yeni haliyle alınır;
            // alan alan karıştırmak tutarsız bir kayıt üretirdi.
            if let newer = newerRecord(l, r) { return newer }
            return mergeObjects(base as? [String: Any], l, r)
        }
        if let l = local as? [Any], let r = remote as? [Any],
           isRecordList(l), isRecordList(r), isRecordList(base as? [Any] ?? []) {
            return mergeArrays(base as? [Any], l, r)
        }
        // Birleşemeyen tekil değer çakışması: bu cihazdaki hal kazanır.
        return local
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return canonical(a) == canonical(b)
        default: return false
        }
    }

    private static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static let stampKeys = ["updatedAt", "lastPlayedAt", "addedAt"]

    private static func newerRecord(_ l: [String: Any], _ r: [String: Any]) -> [String: Any]? {
        for key in stampKeys {
            // ISO-8601 (`...Z`) dizgeleri sözlük sırasında da kronolojik.
            if let a = l[key] as? String, let b = r[key] as? String, a != b { return a > b ? l : r }
            if let a = l[key] as? Double, let b = r[key] as? Double, a != b { return a > b ? l : r }
        }
        return nil
    }

    private static func mergeObjects(_ base: [String: Any]?,
                                     _ local: [String: Any],
                                     _ remote: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Set(local.keys).union(remote.keys) {
            let b = base?[key]
            switch (local[key], remote[key]) {
            case let (l?, r?):
                if let merged = merge(base: b, local: l, remote: r) { out[key] = merged }
            case let (l?, nil):
                // Diğer cihazda silinmiş, burada dokunulmamış: silinir.
                if let b, same(b, l) { continue }
                out[key] = l
            case let (nil, r?):
                if let b, same(b, r) { continue }
                out[key] = r
            case (nil, nil):
                break
            }
        }
        return out
    }

    /// Kimlikle birleştirilebilecek bir liste mi: tamamı nesne ya da tamamı
    /// dizge, ve aynı kimlik iki kez geçmiyor. `[1, 1, 1, 1]` gibi bir renk
    /// dizisi böyle birleşseydi tekrarlar yutulur, değer bozulurdu.
    private static func isRecordList(_ items: [Any]) -> Bool {
        let allObjects = items.allSatisfy { $0 is [String: Any] }
        let allStrings = items.allSatisfy { $0 is String }
        guard allObjects || allStrings else { return false }
        let ids = items.map(identity(of:))
        return Set(ids).count == ids.count
    }

    private static func mergeArrays(_ base: [Any]?, _ local: [Any], _ remote: [Any]) -> [Any] {
        let baseByID = index(base ?? [])
        let remoteByID = index(remote)
        let localIDs = Set(local.map(identity(of:)))
        var out: [Any] = []

        for item in local {
            let id = identity(of: item)
            let b = baseByID[id]
            if let r = remoteByID[id] {
                if let merged = merge(base: b, local: item, remote: r) { out.append(merged) }
            } else if let b, same(b, item) {
                continue          // diğer cihazda silinmiş
            } else {
                out.append(item)  // burada eklenmiş ya da değişmiş
            }
        }
        for item in remote where !localIDs.contains(identity(of: item)) {
            if let b = baseByID[identity(of: item)], same(b, item) { continue }  // burada silinmiş
            out.append(item)
        }
        return out
    }

    private static func index(_ items: [Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for item in items where out[identity(of: item)] == nil {
            out[identity(of: item)] = item
        }
        return out
    }

    /// Bir kaydın kimliği. Modellerin çoğunda `id` var; olmayanlar kendi
    /// doğal anahtarlarıyla (TMDB kimliği, sayfa adresi, akış kimliği…).
    private static let identityKeys: [[String]] = [
        ["id"], ["tmdbID", "kind"], ["providerID", "pageURL"], ["pageURL"],
        ["streamID", "kind"], ["rssLink"], ["magnet"], ["url"]
    ]

    static func identity(of item: Any) -> String {
        if let object = item as? [String: Any] {
            for keys in identityKeys {
                let parts = keys.compactMap { object[$0] }
                if parts.count == keys.count, let data = canonical(parts),
                   let text = String(data: data, encoding: .utf8) {
                    return keys.joined(separator: "+") + "=" + text
                }
            }
        }
        let data = canonical(item) ?? Data()
        return "json=" + (String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Dosyaya özgü biçimler

/// Senkron öncesi/sonrası dosyaya özgü dönüşümler.
enum SyncShape {
    /// Cihaza özgü ayarlar: Drive'a gitmez, buluttan gelen hal yerelini ezmez.
    /// Google istemci bilgileri ayrıca bağlanmanın ön koşulu.
    static let deviceSettingsKeys: Set<String> = [
        "googleClientID", "googleClientSecret", "downloadDirectory",
        "playerControlsOffsetX", "playerControlsOffsetY"
    ]

    /// `[UUID: WatchState]` Swift'te JSON nesnesi değil, `[anahtar, değer,
    /// anahtar, değer…]` dizisi olarak yazılıyor. Kimlikle birleşebilmesi ve
    /// Drive'da okunur olması için senkronda nesneye çevrilir.
    private static let pairArrayFields: [String: String] = ["watchstate.json": "states"]

    static func normalize(_ name: String, _ json: Any) -> Any {
        guard var object = json as? [String: Any] else { return json }
        if name == "settings.json" {
            deviceSettingsKeys.forEach { object.removeValue(forKey: $0) }
        }
        if let field = pairArrayFields[name], let pairs = object[field] as? [Any],
           let dict = dictionary(fromPairs: pairs) {
            object[field] = dict
        }
        return object
    }

    /// `local`, dönüşüm öncesi yerel JSON — cihaza özgü ayarlar oradan geri konur.
    static func denormalize(_ name: String, _ json: Any, local: Any?) -> Any {
        guard var object = json as? [String: Any] else { return json }
        if name == "settings.json", let localObject = local as? [String: Any] {
            for key in deviceSettingsKeys {
                if let value = localObject[key] { object[key] = value }
            }
        }
        if let field = pairArrayFields[name], let dict = object[field] as? [String: Any] {
            object[field] = dict.flatMap { [$0.key, $0.value] as [Any] }
        }
        return object
    }

    private static func dictionary(fromPairs pairs: [Any]) -> [String: Any]? {
        guard pairs.count % 2 == 0 else { return nil }
        var out: [String: Any] = [:]
        var index = 0
        while index < pairs.count {
            guard let key = pairs[index] as? String else { return nil }
            out[key] = pairs[index + 1]
            index += 2
        }
        return out
    }
}

// MARK: - Arka plan birleştirme planı

/// Bir kaynağın senkron girdisi: ana iş parçacığında alınmış anlık görüntü ve
/// o andaki değişiklik sayacı.
struct SyncInput: @unchecked Sendable {
    let name: String
    let snapshot: CloudSyncSnapshot
    let generation: Int
}

/// `[String: Any]` gibi Sendable olmayan JSON değerlerini arka plan işine
/// taşımak için. Değerler yalnızca okunur.
struct SyncBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Senkronun pahalı kısmı: yerel JSON'ların üretilmesi, ortak hal ile üç
/// yönlü birleştirme ve karşılaştırmalar. Hiçbir uygulama durumuna dokunmaz;
/// arka planda çalışır, sonucu ana iş parçacığı uygular.
struct SyncPlan: @unchecked Sendable {
    struct Apply {
        let name: String
        let data: Data
        let generation: Int
    }

    /// Drive'a gidecek dosyalar ve yeni ortak hal.
    var uploadFiles: [String: Any]
    var newBase: [String: Any]
    /// Birleşimi yerelden farklı çıkan, yerele uygulanması gereken dosyalar.
    var applies: [Apply] = []
    /// Ortak hal diskten okunduğu haliyle; geri almalar için.
    let baseFiles: [String: Any]?

    static func make(inputs: [SyncInput], remoteFiles: [String: Any]?) -> SyncPlan {
        let baseFiles = CloudSyncStore.loadBase()
        // Drive'da bu sürümün tanımadığı veriler varsa korunur.
        var plan = SyncPlan(uploadFiles: remoteFiles ?? [:], newBase: baseFiles ?? [:],
                            baseFiles: baseFiles)

        for input in inputs {
            let name = input.name
            let localRaw = input.snapshot.makeData().flatMap {
                try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
            }
            let local = localRaw.map { SyncShape.normalize(name, $0) }
            guard let merged = JSONMerge.merge(base: baseFiles?[name], local: local,
                                               remote: remoteFiles?[name]) else { continue }

            if !JSONMerge.same(merged, local) {
                let full = SyncShape.denormalize(name, merged, local: localRaw)
                guard let data = try? JSONSerialization.data(withJSONObject: full,
                                                             options: [.fragmentsAllowed]) else {
                    NSLog("ZyPlayer senkron: %@ yerele uygulanamadı", name)
                    continue
                }
                plan.applies.append(Apply(name: name, data: data, generation: input.generation))
            }
            plan.uploadFiles[name] = merged
            plan.newBase[name] = merged
        }
        return plan
    }

    /// Yerele uygulanamayan dosya için ne Drive'daki hal ne de ortak hal
    /// ilerletilir; ikisi de bu senkrondan önceki haline döner.
    mutating func revert(_ name: String, remoteFiles: [String: Any]?) {
        uploadFiles[name] = remoteFiles?[name]
        newBase[name] = baseFiles?[name]
    }
}

// MARK: - Drive dosyası

/// Drive'daki tek senkron dosyası: "Drive'ım" kökünde `ZyPlayerData.json`.
struct DriveSyncFile {
    static let fileName = "ZyPlayerData.json"
    var accessToken: String

    enum SyncError: LocalizedError {
        case insufficientScope
        case unauthorized
        case http(Int, String)
        case invalidRemote

        var errorDescription: String? {
            switch self {
            case .insufficientScope:
                "Drive'a yazma izni yok — Google Drive bağlantısını yenileyin."
            case .unauthorized:
                "Drive oturumu geçersiz — yeniden bağlanın."
            case .http(let code, let body):
                "Drive hatası (\(code)): \(body.prefix(160))"
            case .invalidRemote:
                "Drive'daki \(DriveSyncFile.fileName) okunamadı; üzerine yazılmadı."
            }
        }
    }

    /// Drive'daki dosya ve içeriği; dosya yoksa nil.
    func download() async throws -> (id: String, bundle: [String: Any])? {
        guard let id = try await findFileID() else { return nil }
        var request = authorized(URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await send(request)
        // Oluşturulup içeriği yazılamamış boş bir dosya: veri yok sayılır.
        guard !data.isEmpty else { return (id, ["files": [String: Any]()]) }
        guard let bundle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              bundle["files"] is [String: Any] else {
            throw SyncError.invalidRemote
        }
        return (id, bundle)
    }

    /// Var olan dosyayı günceller ya da yenisini oluşturur.
    func upload(_ data: Data, existingID: String?) async throws {
        if let existingID {
            var request = authorized(URL(string:
                "https://www.googleapis.com/upload/drive/v3/files/\(existingID)?uploadType=media")!)
            request.httpMethod = "PATCH"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            _ = try await send(request)
            return
        }

        let boundary = "zyplayer-\(UUID().uuidString)"
        let metadata = #"{"name":"\#(Self.fileName)","mimeType":"application/json"}"#
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(Data(metadata.utf8))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = authorized(URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await send(request)
    }

    /// Çöpte olmayan, en son değişmiş senkron dosyası.
    private func findFileID() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: "name = '\(Self.fileName)' and trashed = false"),
            .init(name: "spaces", value: "drive"),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "fields", value: "files(id)"),
            .init(name: "pageSize", value: "1")
        ]
        let data = try await send(authorized(components.url!))
        struct Listing: Decodable { struct File: Decodable { var id: String }; var files: [File] }
        return try JSONDecoder().decode(Listing.self, from: data).files.first?.id
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 401 { throw SyncError.unauthorized }
            if status == 403, body.contains("insufficient") || body.contains("SCOPE") {
                throw SyncError.insufficientScope
            }
            throw SyncError.http(status, body)
        }
        return data
    }
}

// MARK: - Senkron deposu

/// Devam noktaları, favoriler, izleme durumu ve ayarlar Drive'daki tek bir
/// JSON'la senkron tutulur.
///
/// Yerel dosyalar silinmez, değiştirilmez: hâlâ uygulamanın asıl deposu ve
/// çevrimdışı önbelleğidir. Senkron yalnızca iki tarafı birleştirir — açılışta,
/// yerel bir değişiklikten kısa süre sonra, uygulama öne geldiğinde, birkaç
/// dakikada bir ve kapanırken. İlk senkrondan önce tüm yerel veriler bir kez
/// `Yedekler/` altına kopyalanır.
@MainActor
@Observable
final class CloudSyncStore {
    static weak var shared: CloudSyncStore?

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { Task { await syncNow() } } else { statusMessage = "Kapalı" }
        }
    }
    private(set) var isSyncing = false
    private(set) var statusMessage = ""
    private(set) var lastSyncAt: Date?
    /// Drive bağlantısı yalnızca okuma izniyle kurulmuş; yazmak için kullanıcı
    /// bir kez yeniden bağlanmalı.
    private(set) var needsReconnect = false

    @ObservationIgnored private let drive: GoogleDriveStore
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    private static let enabledKey = "com.zyplayer.cloudSyncEnabled"
    private static let backupDoneKey = "com.zyplayer.cloudSyncBackupDone"
    nonisolated static let baseURL = AppPaths.file("cloud-sync-base.json")

    init(drive: GoogleDriveStore) {
        self.drive = drive
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        Self.shared = self
    }

    var hasPendingChanges: Bool { isEnabled && (isDirty || scheduled != nil) }

    /// Açılışta bir kez çağrılır.
    func start() {
        guard !started else { return }
        started = true
        CloudSyncRegistry.onLocalChange = { [weak self] in self?.noteLocalChange() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (self.lastSyncAt ?? .distantPast).timeIntervalSinceNow < -120 {
                    Task { await self.syncNow() }
                }
            }
        }
        // Başka bir Mac'teki değişiklikler de gelsin.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncNow() }
            }
        }
        Task { await syncNow() }
    }

    /// Yerel değişiklik: hemen değil, kısa bir süre sonra senkronlanır. Oynatma
    /// sırasında devam noktası birkaç saniyede bir yazılıyor; her yazmada Drive'a
    /// gitmek yerine en fazla 20 saniyede bir gidilir — video oynarken 2
    /// dakikada bir (kapanışta ve 5 dakikalık zamanlayıcıda yine gider).
    private func noteLocalChange() {
        isDirty = true
        schedule(after: localChangeDelay)
    }

    private var localChangeDelay: Double {
        CloudSyncRegistry.isPlaybackActive ? 120 : 20
    }

    private func schedule(after seconds: Double) {
        guard isEnabled, scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            await self.syncNow()
        }
    }

    /// Kapanışta bekleyen değişiklikleri en fazla `timeout` saniye içinde gönderir.
    func flush(timeout: Double) async {
        scheduled?.cancel()
        scheduled = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.syncNow() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    func syncNow() async {
        guard isEnabled else { return }
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        isDirty = false
        defer {
            isSyncing = false
            if isDirty || rerunRequested {
                rerunRequested = false
                schedule(after: localChangeDelay)
            }
        }

        if GoogleDriveAuth.grantedScopes.map({ !GoogleDriveAuth.canWrite(scopes: $0) }) == true {
            needsReconnect = true
        }
        statusMessage = "Senkronlanıyor…"

        do {
            let token = try await drive.syncAccessToken()
            let file = DriveSyncFile(accessToken: token)
            let remote = try await file.download()
            let remoteFiles = remote?.bundle["files"] as? [String: Any]

            backupLocalDataOnce()

            // Ana iş parçacığında yalnızca değerlerin kopyası alınır. JSON
            // kodlama, birleştirme ve karşılaştırma (onlarca–yüzlerce ms) arka
            // planda yapılır: video kareleri ana iş parçacığında çiziliyor ve
            // bu iş oynatma sırasında ~20 saniyede bir takılma yapıyordu.
            let inputs = CloudSyncRegistry.syncedNames.map { name in
                SyncInput(name: name,
                          snapshot: CloudSyncRegistry.source(named: name).syncSnapshot(),
                          generation: CloudSyncRegistry.generation(of: name))
            }
            let remoteBox = SyncBox(remoteFiles)
            var plan = await Task.detached(priority: .utility) {
                SyncPlan.make(inputs: inputs, remoteFiles: remoteBox.value)
            }.value
            var appliedCount = 0

            // Drive'dan gelen değişiklikler yerele burada, ana iş parçacığında
            // uygulanır (yalnızca başka cihazda değişiklik varsa iş çıkar).
            for apply in plan.applies {
                let unchanged = CloudSyncRegistry.generation(of: apply.name) == apply.generation
                if unchanged, CloudSyncRegistry.source(named: apply.name).importFromSync(apply.data) {
                    appliedCount += 1
                    continue
                }
                if unchanged {
                    // Uygulanamadı: ne Drive'daki ne yereldeki hal ezilir, ortak
                    // hal de ilerletilmez; bir sonraki senkron yeniden dener.
                    NSLog("ZyPlayer senkron: %@ yerele uygulanamadı", apply.name)
                } else {
                    // Birleştirirken yerel dosya değişti: yeni değişiklik
                    // ezilmesin, bu dosya bir sonraki senkronda birleşir.
                    isDirty = true
                }
                plan.revert(apply.name, remoteFiles: remoteFiles)
            }

            let finalPlan = plan
            let upload = await Task.detached(priority: .utility) { () -> Data? in
                guard remoteBox.value == nil
                        || !JSONMerge.same(finalPlan.uploadFiles, remoteBox.value) else { return nil }
                return try? Self.makeBundle(finalPlan.uploadFiles)
            }.value
            if let upload {
                try await file.upload(upload, existingID: remote?.id)
            }
            await Task.detached(priority: .utility) { Self.saveBase(finalPlan.newBase) }.value

            needsReconnect = false
            lastSyncAt = .now
            statusMessage = appliedCount > 0
                ? "Senkronlandı · Drive'dan \(appliedCount) değişiklik alındı"
                : "Senkronlandı"
        } catch DriveSyncFile.SyncError.insufficientScope {
            needsReconnect = true
            isDirty = true
            statusMessage = DriveSyncFile.SyncError.insufficientScope.errorDescription ?? ""
        } catch let error as GoogleDriveAuth.AuthError {
            // Yenileme jetonu geçersiz (ör. Google "Testing" modundaki istemcilerde
            // 7 günde bir düşüyor): kullanıcı yeniden bağlanmalı.
            needsReconnect = true
            isDirty = true
            statusMessage = "Drive oturumu düştü, yeniden bağlanın. (\(error.localizedDescription))"
        } catch DriveSyncFile.SyncError.unauthorized {
            needsReconnect = true
            isDirty = true
            statusMessage = DriveSyncFile.SyncError.unauthorized.errorDescription ?? ""
        } catch is CancellationError {
            isDirty = true
        } catch let error as URLError where error.code == .cancelled {
            isDirty = true
        } catch {
            // Gönderilemeyen değişiklik kaybolmasın: bir sonraki denemede gider.
            isDirty = true
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Dışa / içe aktarma

    /// Senkronlanan bütün verileri Drive dosyasıyla aynı biçimde tek bir
    /// JSON'a yazar. Drive bağlantısı gerekmez.
    func exportData(to url: URL) throws {
        var files: [String: Any] = [:]
        for name in CloudSyncRegistry.syncedNames {
            guard let data = CloudSyncRegistry.source(named: name).exportForSync(),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            files[name] = SyncShape.normalize(name, json)
        }
        try Self.makeBundle(files).write(to: url, options: .atomic)
    }

    /// Dışa aktarılmış bir dosyayı (ya da Drive'dan indirilmiş
    /// `ZyPlayerData.json`'ı) yerel verilerle birleştirir. Ortak hal
    /// verilmediği için hiçbir yerel kayıt silinmez; aynı kaydın iki hali
    /// varsa daha yeni olan alınır. Ardından Drive'a da gönderilir.
    /// Dönüş: değişen veri kümesi sayısı.
    @discardableResult
    func importData(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let bundle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = bundle["files"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Bu dosya bir ZyPlayer veri dosyası değil."
            ])
        }
        backupLocalDataOnce()
        var changed = 0
        for name in CloudSyncRegistry.syncedNames {
            guard let incoming = files[name] else { continue }
            let source = CloudSyncRegistry.source(named: name)
            let localRaw = source.exportForSync().flatMap {
                try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
            }
            let local = localRaw.map { SyncShape.normalize(name, $0) }
            guard let merged = JSONMerge.merge(base: nil, local: local, remote: incoming),
                  !JSONMerge.same(merged, local) else { continue }
            let full = SyncShape.denormalize(name, merged, local: localRaw)
            if let out = try? JSONSerialization.data(withJSONObject: full, options: [.fragmentsAllowed]),
               source.importFromSync(out) {
                changed += 1
            }
        }
        if changed > 0 { noteLocalChange() }
        return changed
    }

    // MARK: - Dosyalar

    nonisolated static func makeBundle(_ files: [String: Any]) throws -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let bundle: [String: Any] = [
            "format": 1,
            "app": "ZyPlayer",
            "appVersion": version,
            "updatedAt": ISO8601DateFormatter().string(from: .now),
            "files": files
        ]
        return try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
    }

    /// Son başarılı senkronun ortak hali. Yoksa (ilk senkron ya da dosya
    /// silinmiş) birleştirme hiçbir şeyi silmez, iki tarafın birleşimini alır.
    nonisolated static func loadBase() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Self.baseURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return object["files"] as? [String: Any]
    }

    nonisolated static func saveBase(_ files: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["files": files],
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: Self.baseURL, options: .atomic)
    }

    /// İlk senkrondan önce senkronlanan bütün yerel verilerin bir kopyası:
    /// `Application Support/ZyPlayer/Yedekler/bulut-oncesi-<tarih>/`.
    private func backupLocalDataOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.backupDoneKey) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let directory = AppPaths.supportDirectory
            .appendingPathComponent("Yedekler", isDirectory: true)
            .appendingPathComponent("bulut-oncesi-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in CloudSyncRegistry.syncedNames {
                if name.hasPrefix("defaults:") {
                    let key = String(name.dropFirst("defaults:".count))
                    if let data = UserDefaults.standard.data(forKey: key) {
                        try data.write(to: directory.appendingPathComponent("\(key).json"))
                    }
                } else {
                    let source = AppPaths.file(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source,
                                                         to: directory.appendingPathComponent(name))
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: Self.backupDoneKey)
        } catch {
            NSLog("ZyPlayer senkron: yedek alınamadı (%@)", String(describing: error))
        }
    }
}
