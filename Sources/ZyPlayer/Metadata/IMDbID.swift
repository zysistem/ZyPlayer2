import Foundation

/// Arama kutusuna yazılan metinden IMDb kimliğini (`tt33499146`) çıkarır.
/// Hem düz kimlik hem de bir IMDb bağlantısı kabul edilir:
///
///     tt33499146
///     https://www.imdb.com/title/tt33499146
///     https://www.imdb.com/title/tt33499146/?ref_=nv_sr_1
///
/// Başlık araması yerine kimlikle arama yapmak, TMDB'nin `find` uç noktasıyla
/// tek ve kesin bir eşleşme verir — ismi yazınca bulunamayan yeni ya da adı
/// başka dilde geçen yapımlar böyle bulunur.
enum IMDbID {
    /// Kimliği ayıklar; metin ne düz kimlik ne de IMDb bağlantısıysa `nil`.
    ///
    /// Kasıtlı olarak dar tutuldu: rastgele bir başlık aramasının içinde geçen
    /// bir sözcük yanlışlıkla kimlik sanılmasın diye ya metnin tamamı kimlik
    /// olmalı ya da metin bir IMDb adresi olmalıdır.
    static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Metnin tamamı kimlikse doğrudan al.
        if let id = match(trimmed, pattern: #"^tt\d{7,}$"#) { return id }

        // Değilse yalnızca IMDb adreslerinde ara; başka bir sitenin adresinde
        // geçen benzer bir dizi kimlik sayılmaz.
        guard trimmed.range(of: #"(^|\.)imdb\.com"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
                || trimmed.localizedCaseInsensitiveContains("imdb.com/title/")
        else { return nil }
        return match(trimmed, pattern: #"tt\d{7,}"#)
    }

    /// Metnin IMDb kimliği ya da bağlantısı olup olmadığı — arama akışında
    /// "başlık mı arıyoruz, kimlik mi" ayrımı için.
    static func isIMDbQuery(_ text: String) -> Bool { extract(from: text) != nil }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let range = text.range(of: pattern,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(text[range]).lowercased()
    }
}
