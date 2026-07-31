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
# 3. Derle:
xcodebuild -project ZyPlayer.xcodeproj -scheme ZyPlayer -configuration Debug build
```

`xcodegen generate` adımı atlanırsa `.xcodeproj` eski sürümde kalır ve artırım
hiçbir yere yansımaz.

## Derlemeyi doğrulama

"Derlendi" demek yeterli değil — kullanıcı değişikliği görebilmeli. Derledikten
sonra uygulamayı çalıştır ve sürümün gerçekten yeni olduğunu doğrula:

```sh
APP=~/Library/Developer/Xcode/DerivedData/ZyPlayer-*/Build/Products/Debug/ZyPlayer.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
pkill -x ZyPlayer; open "$APP"
```

## Bağlam

Tam durum, mimari kararlar ve karşılaşılan tuzaklar için:
`~/.claude/plans/bu-uygulamay-tersine-m-hendislik-flickering-whistle.md`
Özellikle "veri kaybı olayı" bölümleri ve saklanan modellere alan eklerken
uygulanan toleranslı `init(from:)` kuralı.

## Açıklama

Her zaman her yazdığın türkçe olsun, anlamamı kolaylaştırsın.