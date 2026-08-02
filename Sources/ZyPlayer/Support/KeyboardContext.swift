import AppKit

/// Oynatıcının klavye kısayollarının susması gereken durumlar.
///
/// Oynatıcı boşluk, ok tuşları ve backspace'i çıplak kısayol olarak kullanır.
/// Kullanıcı bir metin alanına yazarken bu tuşların yutulması yazmayı
/// imkânsız kılar: altyazı arama kutusunda backspace'in harf silmek yerine
/// oynatıcıyı kapatmasının sebebi buydu.
///
/// Kontrol tek bir yerde durur, çünkü aynı mantığın iki kopyası (tuş izleyici
/// ve Bluetooth kumanda) birbirinden habersiz sapmıştı.
enum KeyboardContext {

    /// Oynatıcının üstünde bir panel (altyazı arama gibi) açık mı.
    ///
    /// Doğrudan bildirilir, pencere hiyerarşisinden çıkarılmaz: sunum biçimi
    /// beklenenden farklı olduğunda tahmin sessizce yanlışa düşüyor ve tuşlar
    /// oynatıcıya kaçıyordu. Paneli açan kod zaten açık olduğunu bilir.
    static var isPanelOpen = false

    /// Tuşun kısayol değil, girdi sayılması gereken bir bağlamda olup olmadığı.
    static var isTyping: Bool {
        if isPanelOpen { return true }

        // Bir sayfa (sheet) açıkken oynatıcının hiçbir kısayolu geçerli değil.
        // Sırası önemli: sheet sunulduğunda anahtar pencere sheet'in kendisidir,
        // dolayısıyla yalnızca `keyWindow.sheets` bakmak onu asla göremez —
        // sheet'in kendi alt sheet'i yoktur ve liste boş görünür.
        if NSApp.windows.contains(where: { !$0.sheets.isEmpty }) { return true }

        guard let window = NSApp.keyWindow else { return false }
        if window.isSheet { return true }

        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        // SwiftUI'nin metin alanları AppKit sınıflarından türemez; metin girdisi
        // kabul eden her görünümün uyduğu protokol üzerinden tanınırlar.
        if responder is NSTextInputClient { return true }
        return false
    }
}
