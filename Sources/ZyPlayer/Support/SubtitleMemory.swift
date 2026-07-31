import Foundation

/// Bir içerik için yapılan altyazı hareketlerinin hafızası: hangi dosyalar
/// eklendi ve en son hangi iz seçildi.
///
/// İndirilen altyazılar zaten `Application Support/Subtitles` altında kalıcı
/// duruyor; eksik olan, bir sonraki açılışta bunların yeniden eklenmesiydi.
/// mpv dosyayı kapatınca tüm dış altyazı izlerini düşürüyor, dolayısıyla
/// hatırlamak uygulamanın işi.
struct SubtitleMemoryEntry: Codable {
    /// Kullanıcının bu içeriğe eklediği dış altyazı dosyalarının yolları.
    var files: [String] = []
    /// En son seçili olan izin görünen adı ("Türkçe · SUBRIP").
    var selectedLabel: String?
    var updatedAt: Date = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? c.decode([String].self, forKey: .files)) ?? []
        selectedLabel = try? c.decodeIfPresent(String.self, forKey: .selectedLabel)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

private struct SubtitleMemoryData: Codable {
    var videos: [String: SubtitleMemoryEntry] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videos = (try? c.decode([String: SubtitleMemoryEntry].self, forKey: .videos)) ?? [:]
    }
}

enum SubtitleMemory {
    private static let store = LocalStore(fileName: "subtitle-memory.json",
                                          defaultValue: SubtitleMemoryData())

    /// Kullanıcının eklediği bir altyazıyı içeriğe bağlar.
    static func remember(video: String, file: URL) {
        guard !video.isEmpty, file.isFileURL else { return }
        store.update { data in
            var entry = data.videos[video] ?? SubtitleMemoryEntry()
            entry.files.removeAll { $0 == file.path }
            entry.files.append(file.path)
            // Bir içeriğe onlarca altyazı denenebiliyor; son beşi yeter.
            entry.files = Array(entry.files.suffix(5))
            entry.updatedAt = Date()
            data.videos[video] = entry
        }
    }

    /// Seçili izi hatırlar. Kimlikler açılışlar arasında değiştiği için görünen
    /// ad saklanıyor — `applyPreferredSubtitle` de aynı ölçütle eşleştiriyor.
    static func rememberSelection(video: String, label: String?) {
        guard !video.isEmpty else { return }
        store.update { data in
            var entry = data.videos[video] ?? SubtitleMemoryEntry()
            entry.selectedLabel = label
            entry.updatedAt = Date()
            data.videos[video] = entry
        }
    }

    /// İçeriğin hatırlanan durumu. Silinmiş dosyalar elenir.
    static func entry(video: String) -> SubtitleMemoryEntry? {
        guard !video.isEmpty, var entry = store.value.videos[video] else { return nil }
        entry.files = entry.files.filter { FileManager.default.fileExists(atPath: $0) }
        return entry
    }

    /// Kaç içerik için altyazı hatırlanıyor — ayarlardaki özet için.
    static var rememberedVideoCount: Int {
        store.value.videos.count
    }

    static func clear() {
        store.replace(with: SubtitleMemoryData())
    }
}
