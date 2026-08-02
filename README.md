# ZyPlayer

macOS için bir medya oynatıcı ve kütüphane uygulaması. Swift ve SwiftUI ile
yazıldı; oynatma tarafında libmpv'nin render API'si bir `NSOpenGLView` üzerine
çiziyor — yani AVFoundation'ın açmadığı biçimler (MKV, çok kanallı ses, gömülü
altyazılar) doğrudan açılıyor.

Amaç, dağınık duran her kaynağı — yerel diski, ağ paylaşımlarını, buluttaki
dosyaları — tek bir posterli arayüzde toplamak ve hepsini aynı oynatıcıyla
açmak.

---

## Neler yapıyor

**Kütüphane.** İzlenen klasörler taranır, dosya adlarından dizi/sezon/bölüm
çıkarılır ve TMDB'den poster, özet, oyuncu ve fragman çekilir. Kaldığın yer her
kaynak için ayrı ayrı hatırlanır; ana ekranda "İzlemeyi Sürdür" rafı olarak
döner.

**Kaynaklar.** Yerel klasörlerin yanında SMB ağ paylaşımları ve Google Drive
bağlanabilir. Drive'daki dosyalar indirilmeden, akıtılarak oynatılır.

**Altyazı.** OpenSubtitles hesabı ya da hesapsız çalışan Stremio altyazı
eklentileri üzerinden arama; bulunan altyazı Google, Z.ai veya OpenRouter ile
Türkçeye çevrilebiliyor. Seçilen dil ve altyazı hatırlanır, sonraki bölümde
kendiliğinden aynısı seçilir.

**Torrent.** Torrentio üzerinden kalite kalite listeleme, WebTorrent ile
indirmeden izleme (parçalar baştan sona sırayla çekilir, oynatıcı yerel HTTP
üzerinden okur) ve aria2 ile klasik indirme. Akış sırasında inen veri geçici
önbelleğe yazılır ve oynatma bitince silinir.

**ZyStream / ZyMovie.** Akış siteleri ve RSS kaynakları üzerinden içerik
listeleme, TMDB eşleştirmesiyle posterli gösterim. Bu siteler birkaç günde bir
alan adı değiştiriyor; uygulama ana sayfalarındaki duyuruyu okuyup yeni adrese
kendiliğinden geçiyor, elle güncelleme gerekmiyor.

**Kumanda.** Klavye kısayollarının yanında oyun kolu ve Bluetooth medya
kumandası desteği var; oynatıcı tam ekranda uzaktan sürülebiliyor.

---

## Gereksinimler

| Ne | Niçin | Kurulum |
|---|---|---|
| macOS 14+ | SwiftUI ve `@Observable` | — |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | `.xcodeproj` üretimi | `brew install xcodegen` |
| Node.js | torrent akış yardımcısı | `brew install node` |
| aria2 | torrent indirme | `brew install aria2` |

Node ve aria2 olmadan da uygulama çalışır — yalnızca ilgili bölümler kendini
kapatır ve nedenini söyler.

---

## Derleme

`.xcodeproj` **üretilmiş** bir dosyadır; kaynağı `project.yml`'dir ve elle
düzenlenmez. Sürüm numarası her derlemede artırılır, böylece "Hakkında"
penceresinden hangi yapının çalıştığı görülebilir.

```sh
# 1. project.yml içindeki MARKETING_VERSION'ı +0.0.1 yükselt
# 2. Projeyi yeniden üret — sürüm .xcodeproj'e ancak böyle işlenir:
xcodegen generate
# 3. Derle:
xcodebuild -project ZyPlayer.xcodeproj -scheme ZyPlayer -configuration Debug build
```

`xcodegen generate` atlanırsa `.xcodeproj` eski sürümde kalır ve artırım hiçbir
yere yansımaz.

Çalıştırıp sürümü doğrulamak için:

```sh
APP=~/Library/Developer/Xcode/DerivedData/ZyPlayer-*/Build/Products/Debug/ZyPlayer.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
pkill -x ZyPlayer; open "$APP"
```

---

## Kod düzeni

```
Sources/ZyPlayer/
  App/           Uygulama girişi, pencere ve yaşam döngüsü
  Player/        libmpv köprüsü, oynatıcı arayüzü, kumanda desteği
  Library/       Klasör tarama, dosya adı ayrıştırma, izleme durumu
  MediaSources/  Torrent motoru ve akış kaynakları
    Stream/        Akış siteleri, alan adı takibi, sayfa çözümleme
  Metadata/      TMDB ve IMDb tarafı
  Support/       Ayarlar, yerel saklama, önbellekler
  UI/            Ekranlar
Vendor/
  TorrentStream/ Yamalanmış WebTorrent yardımcısı (Node)
```

Saklanan modellere alan eklerken `init(from:)` **toleranslı** yazılır —
eksik alan varsayılana düşer, eski kayıtlar okunmaya devam eder. Bu kural bir
veri kaybı olayının ardından konuldu ve istisnasızdır.

---

## Not

Uygulamanın akış ve torrent bölümleri, adresi kullanıcı tarafından girilen
üçüncü taraf kaynaklara bağlanır. Bu kaynakların içeriğinden ve yasal
durumundan uygulama sorumlu değildir; yapıları sık değiştiği için zaman zaman
çalışmayabilirler. Kendi içeriğinizle ya da erişim hakkına sahip olduğunuz
kaynaklarla kullanın.

Kişisel bir projedir, olduğu gibi sunulur.
