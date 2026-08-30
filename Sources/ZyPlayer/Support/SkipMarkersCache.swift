import Foundation

/// Bölüm/film başına tespit edilen "Tanıtımı Geç" / "Sonraki Bölüm" sınırlarını
/// diskte saklar.
///
/// ffmpeg analizi (sessizlik + siyah kare taraması, bkz. `IntroSkipDetector`)
/// gerçek zamanda saniyeler sürebiliyor — özellikle ağ üzerinden akan bir
/// dosyada, ilk ~170 sn'nin indirilip çözülmesi gerekiyor. Önbellek yoksa bu
/// analiz içerik her açıldığında sıfırdan tekrarlanıyor, düğme de her seferinde
/// aynı gecikmeyle beliriyordu. `WatchFlagsStore`/`TranslatedSubtitleCache` ile
/// aynı `LocalStore` deseni: video kimliğine (akış/torrent'te `resumeKey`,
/// kütüphanede dosya URL'i) göre anahtarlanan basit bir sözlük.
///
/// "Hiç bulunamadı" sonucu da (`SkipMarkers()`, `source == .none`) geçerli bir
/// sonuçtur ve saklanır — yoksa tanıtımsız bir bölüm her açılışta boşuna
/// yeniden analiz edilirdi.
enum SkipMarkersCache {
    private static let file = LocalStore(fileName: "skip-markers.json",
                                         defaultValue: [String: SkipMarkers]())

    static func load(key: String) -> SkipMarkers? {
        guard !key.isEmpty else { return nil }
        return file.value[key]
    }

    static func store(_ markers: SkipMarkers, key: String) {
        guard !key.isEmpty else { return }
        file.update { entries in
            entries[key] = markers
        }
    }
}
