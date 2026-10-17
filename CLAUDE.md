# ZyPlayer

macOS medya oynatıcı. Swift + SwiftUI, oynatma libmpv render API + `NSOpenGLView`.
`.xcodeproj` **üretilmiş** bir dosyadır — kaynak `project.yml`'dir, elle
düzenlenmez.

## Sürüm numarası — ZORUNLU

**Her derlemede sürüm numarasını +0.0.1 artır.** İstisnası yok: kod değiştiyse ve
derliyorsan, önce sürümü yükselt. Böylece uygulamada hangi yapının çalıştığı
"Hakkında" penceresinden görülebilir ve değişikliğin gerçekten yansıyıp
yansımadığı anlaşılır.

Sıra şudur:

```sh
# 1. project.yml içindeki MARKETING_VERSION'ı +0.0.1 yükselt (ör. 1.0.1 → 1.0.2)
# 2. Projeyi yeniden üret — sürüm .xcodeproj'e ancak böyle işlenir:
xcodegen generate
# 3. Derle (bu Mac'te Xcode YOK — Xcode'suz betik kullanılır):
zsh build/build.sh
```

`xcodegen generate` adımı atlanırsa `.xcodeproj` eski sürümde kalır ve artırım
hiçbir yere yansımaz.

### Xcode'suz derleme (`build/build.sh`)

Bu makinede yalnızca Command Line Tools var; `xcodebuild` çalışmaz
("requires Xcode"). `build/build.sh` kaynakları geçici bir klasöre kopyalayıp
`swiftc` ile derler, `build/ZyPlayer.app` paketini kurar, imzalar ve uygulamayı
kendisi açar. `build/` gitignore'dadır — betik yerel, repoya girmez.

- macOS 27 SDK'sında `@State` makrosu yalnızca Xcode ile geliyor; betik geçici
  kopyada `@State` → `@LocalState` (`build/StateShim.swift`) çevirir. Asıl
  kaynaklara dokunulmaz.
- `Assets.car` yeniden üretilemez (actool = Xcode); paketteki kopya korunur.
- **T7 (exFAT) tuzağı:** macOS her dosyanın yanına `._*` AppleDouble dosyası
  koyuyor. Bunlar kopyalamada sed'i ("illegal byte sequence") ve imzalamayı
  ("._MacOS: Operation not permitted") bozuyordu; betik artık `._*`'ı hariç
  tutuyor ve imzadan önce `dot_clean -m` çalıştırıyor. Bu hatalar yeniden
  görülürse önce `._*` dosyalarından şüphelen.
- Betiğin hata filtresi yalnızca `error` içeren satırları gösterir; Swift 6
  uyarıları ("this is an error in the Swift 6 language mode") derlemeyi
  durdurmaz. Başarı ölçütü son satırdaki `Paket sürümü: X.Y.Z`'dir.

Xcode kurulursa eski yol da geçerli:
`xcodebuild -project ZyPlayer.xcodeproj -scheme ZyPlayer -configuration Debug build`
(çıktı `~/Library/Developer/Xcode/DerivedData/ZyPlayer-*/Build/Products/Debug/`).

## Derlemeyi doğrulama

"Derlendi" demek yeterli değil — kullanıcı değişikliği görebilmeli. Derledikten
sonra uygulamanın çalıştığını ve sürümün gerçekten yeni olduğunu doğrula:

```sh
APP=build/ZyPlayer.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
pgrep -x ZyPlayer || open "$APP"
```

Kullanıcı uygulamayı Masaüstü'ndeki bir kopyadan çalıştırıyor olabilir; yeni
yapının `build/ZyPlayer.app` konumunda olduğunu ona söyle.

## Bağlam

Tam durum, mimari kararlar ve karşılaşılan tuzaklar için:
`~/.claude/plans/bu-uygulamay-tersine-m-hendislik-flickering-whistle.md`
Özellikle "veri kaybı olayı" bölümleri ve saklanan modellere alan eklerken
uygulanan toleranslı `init(from:)` kuralı.

## Açıklama

Her zaman her yazdığın türkçe olsun, anlamamı kolaylaştırsın.