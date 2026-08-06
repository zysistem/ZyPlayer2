import Foundation
import Observation
import AppKit
import MediaPlayer

/// Observable playback state the UI binds to. Owns the mpv engine and keeps a
/// display-rate mirror of its properties.
@Observable
final class PlayerModel {
    @ObservationIgnored let core = MPVCore()

    /// Created once at startup so mpv always has a render context before the
    /// first `loadfile`; otherwise mpv drops the video track outright.
    @ObservationIgnored lazy var renderer: MPVGLView = MPVGLView(core: core)

    var position: Double = 0
    var duration: Double = 0
    var isPaused: Bool = true
    var volume: Double = 100
    var speed: Double = 1.0
    var currentURL: URL?
    var currentTitle: String = ""

    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioID: Int?
    /// `nil` means subtitles are off.
    var selectedSubtitleID: Int?
    var isFullscreen = false
    /// Trailers must not write watch progress against a library item.
    var isTrailer = false
    var isTranslatingSubtitles = false
    var translationMessage: String?

    /// Live subtitle offset in seconds; positive shows the line later. Starts at
    /// the value saved in settings and is nudged from the player while watching,
    /// because sync is a property of the file, not of the app.
    var subtitleDelay: Double = 0
    /// What "sıfırla" goes back to: the delay configured in Settings.
    @ObservationIgnored private var baseSubtitleDelay: Double = 0
    @ObservationIgnored private var currentHTTPHeaders: [String: String] = [:]

    /// Subtitle track ID to source URL mapping for translating external tracks
    @ObservationIgnored var trackURLs: [Int: URL] = [:]

    /// External subtitle tracks to attach once the file is loaded — used by
    /// ZyStream, whose streams carry their subtitles as separate VTT files.
    @ObservationIgnored private var pendingSubtitles: [StreamSubtitle] = []

    /// Stable resume key for a source with no library row (a ZyStream page or a
    /// torrent). While set, progress is reported against this key instead of the
    /// ephemeral media URL. `nil` for library files, which resume by their URL.
    @ObservationIgnored private(set) var currentResumeKey: String?

    /// A subtitle track to re-select once tracks are known — the language the user
    /// last watched this title with. Cleared once matched.
    @ObservationIgnored private var pendingPreferredSubtitle: String?

    /// Kayıtlı çeviri her dosya için bir kez aranır; `fileLoaded` olayı bir
    /// oynatma sırasında birden çok kez gelebiliyor.
    @ObservationIgnored private var didRestoreCachedTranslation = false

    /// Ayarlardaki çeviri motoru. Kayıtlı çeviri ararken hangi motorunkinin
    /// yeğleneceğini belirler; başka motorun çevirisi de kabul edilir.
    @ObservationIgnored var restoreEngineHint: TranslationEngine = .google

    /// Display name of the selected subtitle track, or nil when off. Used to
    /// remember the choice for "continue watching".
    var currentSubtitleLabel: String? {
        guard let id = selectedSubtitleID else { return nil }
        return subtitleTracks.first { $0.id == id }?.displayName
    }

    /// Called roughly every 5s and on close so progress survives a quit.
    @ObservationIgnored var onProgress: ((URL, Double, Double) -> Void)?
    @ObservationIgnored private var lastReportedPosition: Double = 0

    /// Set while the user drags the scrubber so incoming positions don't fight it.
    @ObservationIgnored private var isScrubbing = false
    /// When the last preview seek went to mpv, so a drag issues a handful of cheap
    /// seeks a second instead of one per mouse move.
    @ObservationIgnored private var lastPreviewSeek: TimeInterval = 0
    /// Releases the scrub lock after the final seek; cancelled if a new drag starts.
    @ObservationIgnored private var scrubRelease: DispatchWorkItem?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let powerAssertion = PowerAssertion()

    init() {
        core.start(logFile: Self.logFileURL)
        _ = renderer // force the render context to exist before any playback

        core.onEvent { [weak self] event in
            guard let self else { return }
            switch event {
            case .fileLoaded:
                self.duration = self.core.duration
                self.attachPendingSubtitles()
                self.refreshTracks()
                self.applyPreferredSubtitle()
                self.restoreCachedTranslation()
            case .propertyChanged:
                self.syncFromCore()
            case .endFile, .shutdown:
                break
            }
        }
        startTicker()
    }

    deinit {
        ticker?.invalidate()
        powerAssertion.setActive(false)
        core.shutdown()
    }

    private static var logFileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("mpv.log")
    }

    /// mpv only emits `time-pos` a few times a second; a light timer keeps the
    /// scrubber smooth without polling aggressively.
    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.syncFromCore()
        }
    }

    /// Each assignment is guarded: `@Observable` notifies on every write, equal or
    /// not, and this runs four times a second — an unguarded write rebuilt the
    /// whole transport bar (menus, glass, sliders) on every tick.
    private func syncFromCore() {
        if !isScrubbing, position != core.position { position = core.position }
        if duration != core.duration { duration = core.duration }
        if isPaused != core.isPaused { isPaused = core.isPaused }
        if volume != core.volume { volume = core.volume }
        if speed != core.speed { speed = core.speed }
        // Hold the display awake only while something is actually playing.
        powerAssertion.setActive(currentURL != nil && !isPaused)
        reportProgressIfNeeded()
    }

    /// Persists progress every 5 seconds of playback so quitting mid-film still
    /// resumes correctly — saving only on close loses everything on a hard quit.
    private func reportProgressIfNeeded() {
        guard !isTrailer, let url = currentURL, duration > 0, !isPaused else { return }
        guard abs(position - lastReportedPosition) >= 5 else { return }
        lastReportedPosition = position
        onProgress?(url, position, duration)
    }

    func flushProgress() {
        guard !isTrailer, let url = currentURL, duration > 0 else { return }
        lastReportedPosition = position
        onProgress?(url, position, duration)
    }

    // MARK: - Tracks

    func refreshTracks() {
        let all = core.trackList()
        audioTracks = all.filter { $0.kind == .audio }
        subtitleTracks = all.filter { $0.kind == .sub }
        selectedAudioID = audioTracks.first(where: \.isSelected)?.id
        selectedSubtitleID = subtitleTracks.first(where: \.isSelected)?.id
    }

    func selectAudio(_ track: MediaTrack?) {
        selectedAudioID = track?.id
        core.selectAudioTrack(id: track?.id)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        selectedSubtitleID = track?.id
        core.selectSubtitleTrack(id: track?.id)
        // Seçim de bir altyazı hareketi: aynı içerik yeniden açıldığında aynı iz
        // gelsin diye adıyla saklanıyor.
        SubtitleMemory.rememberSelection(video: translationVideoKey,
                                         label: track?.displayName)
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        baseSubtitleDelay = style.delay
        subtitleDelay = style.delay
        core.applySubtitleStyle(style)
    }

    // MARK: - Subtitle sync

    /// Nudges the offset. mpv accepts `sub-delay` while playing, so the change is
    /// visible on the next line without reloading anything.
    func shiftSubtitleDelay(by seconds: Double) {
        setSubtitleDelay(subtitleDelay + seconds)
    }

    func setSubtitleDelay(_ seconds: Double) {
        // Rounded to a tenth so repeated nudges don't accumulate float dust.
        let clamped = (max(-60, min(60, seconds)) * 10).rounded() / 10
        subtitleDelay = clamped
        core.setProperty("sub-delay", clamped)
    }

    /// Back to the value configured in Settings.
    func resetSubtitleDelay() {
        setSubtitleDelay(baseSubtitleDelay)
    }

    func addSubtitleFile(_ url: URL, title: String? = nil, lang: String? = nil,
                         remember: Bool = true) {
        core.addSubtitleFile(url, title: title, lang: lang)
        // Kullanıcının kendi eklediği altyazılar içeriğe bağlanıyor ki bir
        // sonraki açılışta yeniden yüklensin. Çevirinin ürettiği geçici
        // dosyaların kendi kaydı var, onlar buraya girmiyor.
        if remember { SubtitleMemory.remember(video: translationVideoKey, file: url) }
        // mpv assigns the new track an id only once it has loaded it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.refreshTracks()
            let currentIDs = self.subtitleTracks.map(\.id)
            for id in currentIDs {
                if self.trackURLs[id] == nil {
                    self.trackURLs[id] = url
                }
            }
        }
    }

    /// Attaches the streaming source's external subtitles once the file loads.
    /// mpv sends `--referrer`/`--user-agent` with these fetches too, so a
    /// Referer-gated VTT still downloads.
    private func attachPendingSubtitles() {
        guard !pendingSubtitles.isEmpty else { return }
        for sub in pendingSubtitles {
            let target = sub.url.isFileURL ? sub.url.path : sub.url.absoluteString
            core.command(["sub-add", target, "auto", sub.label ?? "Altyazı"])
        }
        let attached = pendingSubtitles
        pendingSubtitles = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshTracks()
            self.applyPreferredSubtitle()
            
            // Map the newly added tracks to their source URLs
            for (index, sub) in attached.enumerated() {
                if let match = self.subtitleTracks.first(where: {
                    $0.title == sub.label || $0.displayName.localizedCaseInsensitiveContains(sub.label ?? "")
                }) {
                    self.trackURLs[match.id] = sub.url
                } else {
                    let trackIndex = self.subtitleTracks.count - attached.count + index
                    if trackIndex >= 0 && trackIndex < self.subtitleTracks.count {
                        self.trackURLs[self.subtitleTracks[trackIndex].id] = sub.url
                    }
                }
            }
        }
    }

    @MainActor
    func translateSelectedSubtitle(engine: TranslationEngine,
                                   zaiApiKey: String,
                                   openRouterApiKey: String,
                                   openRouterModel: String) async {
        guard let selectedID = selectedSubtitleID else { return }

        // Kaynak ya bizim eklediğimiz dosya ya da mpv'nin videonun yanından
        // kendiliğinden bulduğu bir `.srt`; ikisi de yoksa iz gömülüdür.
        var subtitleURL: URL? = trackURLs[selectedID] ?? subtitleTracks
            .first { $0.id == selectedID }
            .flatMap { Self.subtitleSourceURL(fromMPVPath: $0.externalFilename) }


        if subtitleURL == nil {
            // It's an embedded subtitle! Try to extract it using ffmpeg.
            guard let videoURL = currentURL else {
                translationMessage = "Hata: Video kaynağı bulunamadı."
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.translationMessage = nil
                }
                return
            }
            
            guard let selectedTrack = subtitleTracks.first(where: { $0.id == selectedID }),
                  let ffIndex = selectedTrack.ffIndex else {
                translationMessage = "Gömülü altyazı akış bilgisi bulunamadı."
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.translationMessage = nil
                }
                return
            }

            // PGS/VobSub izleri metin değil resimdir; ffmpeg bunları yazıya
            // çeviremez (bunun için OCR gerekir). Kullanıcıyı belirsiz bir
            // "ffmpeg hatası" yerine doğrudan uyarıyoruz.
            if let codec = selectedTrack.codec?.lowercased(),
               ["pgs", "hdmv", "dvd_sub", "dvdsub", "dvb_sub", "vobsub", "xsub"]
                   .contains(where: { codec.contains($0) }) {
                translationMessage = "Bu iz resim tabanlı bir altyazı (\(selectedTrack.codec ?? "")); "
                    + "metne çevrilemez. \"Altyazı Ara…\" menüsünden metin altyazı indirin."
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    self?.translationMessage = nil
                }
                return
            }

            isTranslatingSubtitles = true
            translationMessage = "Gömülü altyazı çıkartılıyor..."

            NSLog("ZyPlayer gömülü altyazı: iz=%d codec=%@ ff-index=%d kaynak=%@",
                  selectedID, selectedTrack.codec ?? "?", ffIndex, videoURL.absoluteString)

            do {
                let extractedURL = try await extractEmbeddedSubtitle(from: videoURL, ffIndex: ffIndex)
                subtitleURL = extractedURL
                // Aynı iz yeniden çevrilmek istenirse ffmpeg'i tekrar
                // çalıştırmaya gerek kalmasın.
                trackURLs[selectedID] = extractedURL
            } catch {
                isTranslatingSubtitles = false
                translationMessage = "Ayıklama Hatası: \(error.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    self?.translationMessage = nil
                }
                return
            }
        }
        
        guard let url = subtitleURL else {
            isTranslatingSubtitles = false
            translationMessage = nil
            return
        }

        isTranslatingSubtitles = true
        translationMessage = "Altyazı hazırlanıyor..."
        defer {
            isTranslatingSubtitles = false
            translationMessage = nil
        }

        do {
            let content = try await readSubtitle(at: url)
            let cues = SubtitleTranslator.parse(content)
            guard !cues.isEmpty else {
                throw NSError(domain: "Translation", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Geçerli altyazı satırı bulunamadı"
                ])
            }

            let cacheKey = TranslatedSubtitleCache.key(source: content)

            // Bu altyazı daha önce çevrildiyse ağa hiç çıkmıyoruz — hangi motorla
            // çevrilmiş olursa olsun.
            if let hit = TranslatedSubtitleCache.cached(key: cacheKey, preferring: engine) {
                translationMessage = "Kayıtlı çeviri yükleniyor..."
                _ = await attachTranslatedSubtitle(at: hit.url)
                translationMessage = "Kayıtlı çeviri yüklendi (\(hit.engineName))."
                try? await Task.sleep(for: .seconds(2.0))
                return
            }

            // Çeviri başlamadan önce özgün metinle bir dosya yazılıp ize
            // ekleniyor. Böylece kullanıcı beklemeden izlemeye devam ediyor;
            // her parti bittikçe aynı dosya güncellenip mpv'ye yeniden okutuluyor.
            let workingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("zyplayer_ceviri_\(UUID().uuidString).vtt")
            var translatedCues = cues
            try SubtitleTranslator.buildWebVTT(cues: translatedCues)
                .write(to: workingURL, atomically: true, encoding: .utf8)

            let trackID = await attachTranslatedSubtitle(at: workingURL)

            let allTexts = cues.map(\.text)
            let batches: [Range<Int>]
            let parallel: Int
            switch engine {
            case .google:
                // Anahtarsız uç arka arkaya gelen isteklerde IP'yi engelliyor,
                // bu yüzden aynı anda en çok iki istek.
                batches = TranslationUtil.chunks(allTexts,
                                                 maxLines: GoogleTranslator.maxLinesPerRequest,
                                                 maxChars: GoogleTranslator.maxCharsPerRequest)
                parallel = 2
            case .zai:
                // GLM-4.5-flash uzun partilerde satır atlıyor; kısa partiler
                // eksik çeviri oranını düşürüyor. Ücretsiz katman ayrıca dörtte
                // hız sınırına takıldığı için paralellik 2'de kalıyor.
                batches = TranslationUtil.chunks(allTexts,
                                                 maxLines: ZaiTranslator.maxLinesPerRequest,
                                                 maxChars: 3000)
                parallel = 2
            case .openRouter:
                // Yapay zeka partileri tek tek 10-90 saniye sürüyor; asıl
                // hızlanma bunları aynı anda göndermekten geliyor.
                batches = TranslationUtil.chunks(allTexts,
                                                 maxLines: LLMTranslator.maxLinesPerRequest,
                                                 maxChars: 6000)
                parallel = 4
            }

            var done = 0
            var failed = 0
            var lastError: Error?
            var changed = 0

            // Partiler paralel gidiyor ama sonuçlar geldikçe işleniyor: hangisi
            // önce dönerse altyazı o an güncelleniyor, sıra beklenmiyor.
            try await withThrowingTaskGroup(of: (Range<Int>, [String]?, Error?).self) { group in
                var next = 0
                func submit(_ range: Range<Int>) {
                    let texts = Array(allTexts[range])
                    group.addTask {
                        do {
                            let out: [String]
                            switch engine {
                            case .zai:
                                out = try await ZaiTranslator.translateBatch(texts, apiKey: zaiApiKey)
                            case .openRouter:
                                out = try await OpenRouterTranslator.translateBatch(
                                    texts, apiKey: openRouterApiKey, preferredModel: openRouterModel)
                            case .google:
                                out = try await GoogleTranslator.translateBatch(texts)
                            }
                            return (range, out, nil)
                        } catch {
                            return (range, nil, error)
                        }
                    }
                }

                while next < batches.count, next < parallel {
                    submit(batches[next]); next += 1
                }

                while let (range, texts, error) = try await group.next() {
                    done += 1
                    if let texts {
                        for (offset, index) in range.enumerated() where offset < texts.count {
                            let text = texts[offset]
                            if !text.isEmpty, text != translatedCues[index].text {
                                translatedCues[index].text = text
                                changed += 1
                            }
                        }
                        // Çevrilen kısım hemen ekrana: dosya yerinde güncellenip
                        // mpv'ye yeniden okutuluyor, iz ve seçim değişmiyor.
                        if let trackID {
                            try? SubtitleTranslator.buildWebVTT(cues: translatedCues)
                                .write(to: workingURL, atomically: true, encoding: .utf8)
                            core.reloadSubtitle(id: trackID)
                        }
                    } else {
                        failed += 1
                        lastError = error
                    }

                    let percent = Int(Double(done) / Double(batches.count) * 100)
                    translationMessage = failed > 0
                        ? "Çevriliyor: %\(percent) (\(failed) parça atlandı)"
                        : "Çevriliyor: %\(percent)"

                    if next < batches.count {
                        submit(batches[next]); next += 1
                    }
                }
            }

            guard changed > 0 else {
                throw lastError ?? NSError(domain: "Translation", code: 3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Çeviri motoru altyazıyı değiştirmeden döndürdü. Ayarlar'dan başka bir motor deneyin."
                ])
            }

            let finalVTT = SubtitleTranslator.buildWebVTT(cues: translatedCues)
            try finalVTT.write(to: workingURL, atomically: true, encoding: .utf8)
            if let trackID { core.reloadSubtitle(id: trackID) }

            // Yalnızca tamamı biten çeviri saklanıyor; yarım kalan bir çeviri
            // sonraki açılışta eksik görünmesin diye önbelleğe girmiyor.
            if failed == 0, let stored = TranslatedSubtitleCache.store(finalVTT, key: cacheKey,
                                                                      engine: engine) {
                // Videonun kendi kimliğine de yazılıyor: içerik kapatılıp
                // açıldığında kaynak altyazı artık ekli olmasa da çeviri bulunsun.
                let label = subtitleTracks.first { $0.id == selectedID }?.displayName ?? "Altyazı"
                TranslatedSubtitleCache.record(video: translationVideoKey, file: stored,
                                               engine: engine, label: label)
            }

            translationMessage = failed == 0
                ? "Çeviri tamamlandı."
                : "Çeviri bitti, \(failed) parça çevrilemedi."
            try? await Task.sleep(for: .seconds(2.0))
        } catch {
            translationMessage = "Hata: \(error.localizedDescription)"
            try? await Task.sleep(for: .seconds(4.0))
        }
    }

    /// Dosya açılırken, ekli altyazılardan herhangi biri daha önce çevrildiyse o
    /// çeviriyi kendiliğinden yükler ve seçer.
    ///
    /// Kullanıcının beklediği davranış bu: bir içeriği bir kez çevirdiyse,
    /// yeniden açtığında çeviri menüye gidip düğmeye basmadan gelmeli. Önbellek
    /// aramaları içerik özetine dayandığı için hangi motorla çevrildiği fark
    /// etmiyor.
    private func restoreCachedTranslation() {
        // Aynı oynatma için bir kez.
        guard !didRestoreCachedTranslation else { return }
        didRestoreCachedTranslation = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            let video = self.translationVideoKey
            let memory = SubtitleMemory.entry(video: video)
            var restoredSomething = false

            // 1) Kullanıcının bu içeriğe eklediği altyazılar yeniden yüklenir.
            // mpv dosyayı kapatınca dış izleri düşürüyor, dolayısıyla indirilen
            // altyazı diskte dursa da kendiliğinden geri gelmiyordu.
            for path in memory?.files ?? [] {
                let url = URL(fileURLWithPath: path)
                // `remember: false`: zaten hafızadan geliyor, listeyi yeniden
                // yazmaya gerek yok.
                self.addSubtitleFile(url, remember: false)
                restoredSomething = true
                try? await Task.sleep(for: .milliseconds(250))
            }

            // 2) Bu içeriğin çevirisi varsa o da bir iz olarak eklenir. Videonun
            // kendi kaydına bakıyoruz: kaynak altyazının ekli olmasını
            // gerektirmediği için kapat-aç akışında çalışan tek yol bu.
            if let (entry, url) = TranslatedSubtitleCache.entries(video: video).first {
                let engine = TranslationEngine(rawValue: entry.engine)?.title ?? "kayıtlı"
                _ = await self.attachTranslatedSubtitle(at: url)
                restoredSomething = true
                if memory?.selectedLabel == nil {
                    self.translationMessage = "Kayıtlı çeviri yüklendi (\(engine))."
                    try? await Task.sleep(for: .seconds(2.5))
                    self.translationMessage = nil
                }
            }

            // 3) En son hangi iz seçiliyse ona dönülür — çeviri de olabilir,
            // indirilen bir altyazı da, gömülü bir iz de.
            if let label = memory?.selectedLabel {
                self.refreshTracks()
                if let match = self.subtitleTracks.first(where: {
                    $0.displayName.localizedCaseInsensitiveContains(label)
                        || label.localizedCaseInsensitiveContains($0.displayName)
                }) {
                    if self.selectedSubtitleID != match.id { self.selectSubtitle(match) }
                    self.translationMessage = "Altyazı geri yüklendi: \(match.displayName)"
                    try? await Task.sleep(for: .seconds(2.0))
                    self.translationMessage = nil
                }
            }

            if restoredSomething { return }

            // `fileLoaded` anında izler çoğu zaman daha yerine oturmamış olur:
            // ZyStream'in dış altyazıları yarım saniye sonra ekleniyor, mpv de
            // videonun yanındaki `.srt`yi kendi zamanında buluyor. Bu yüzden
            // aday çıkana kadar kısa bir süre bekliyoruz.
            var candidates: [URL] = []
            for _ in 0..<12 {   // ~6 saniye
                candidates = self.translatableSubtitleSources()
                if !candidates.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
                self.refreshTracks()
            }

            for url in candidates {
                guard let content = try? await self.readSubtitle(at: url) else { continue }
                let key = TranslatedSubtitleCache.key(source: content)
                guard let hit = TranslatedSubtitleCache.cached(key: key,
                                                              preferring: self.restoreEngineHint)
                else { continue }

                _ = await self.attachTranslatedSubtitle(at: hit.url)
                self.translationMessage = "Kayıtlı çeviri yüklendi (\(hit.engineName))."
                try? await Task.sleep(for: .seconds(2.5))
                self.translationMessage = nil
                return
            }
        }
    }

    /// Çevirileri videoya bağlayan kimlik. Kütüphane dosyalarında yol,
    /// akış/torrent gibi geçici adreslerde ise kalıcı devam anahtarı — ikisi de
    /// aynı içerik yeniden açıldığında değişmiyor.
    private var translationVideoKey: String {
        if let key = currentResumeKey, !key.isEmpty { return key }
        return currentURL?.absoluteString ?? ""
    }

    /// Kaynağı bilinen dış altyazılar: uygulamanın eklediklerinin yanında
    /// mpv'nin kendiliğinden bulduğu yan dosyalar da. Çevirinin kendi ürettiği
    /// izler elenir — yoksa çeviriyi çevirmeye kalkardık.
    private func translatableSubtitleSources() -> [URL] {
        subtitleTracks.compactMap { track -> URL? in
            let url = trackURLs[track.id]
                ?? Self.subtitleSourceURL(fromMPVPath: track.externalFilename)
            guard let url,
                  !url.lastPathComponent.hasPrefix("zyplayer_ceviri_"),
                  url.deletingPathExtension().lastPathComponent.count != 64  // önbellek dosyası
            else { return nil }
            return url
        }
    }

    /// mpv'nin `external-filename` alanını gerçek bir adrese çevirir.
    ///
    /// Çoğu zaman bu bir disk yoludur, ama YouTube fragmanlarında iz uzaktadır:
    /// yt-dlp altyazıyı indirmez, mpv'ye bir EDL sarmalı verir —
    /// `edl://!no_clip;!delay_open,media_type=sub;%333%https://www.youtube.com/api/timedtext?...&fmt=srt`
    /// Buradaki `%333%`, ardından gelen 333 baytın tek bir alan olduğunu
    /// söyleyen mpv'nin uzunluk önekidir.
    ///
    /// Eskiden bu dize olduğu gibi `URL(fileURLWithPath:)`e veriliyordu. Sonuç,
    /// adı "timedtext?v=..." olan var olmayan bir dosya oluyordu; çeviri de
    /// "dosya bulunamadı" diye düşüyordu. Adres artık sarmalın içinden
    /// çıkartılıyor ve ağdan okunuyor.
    static func subtitleSourceURL(fromMPVPath raw: String?) -> URL? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }

        if path.hasPrefix("edl://") {
            guard let inner = edlPayload(String(path.dropFirst(6))) else { return nil }
            path = inner
        }

        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
                ?? URL(string: path.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? path)
        }
        return URL(fileURLWithPath: path)
    }

    /// EDL gövdesinden `%<uzunluk>%` önekli alanı söker.
    private static func edlPayload(_ body: String) -> String? {
        guard let marker = body.range(of: #"%\d+%"#, options: .regularExpression),
              let count = Int(body[marker].dropFirst().dropLast()) else {
            // Uzunluk öneki yoksa son alan adresin kendisidir.
            return body.split(separator: ";").last.map(String.init)
        }
        // Uzunluk bayt cinsinden; adres ASCII dışı karakter içerebiliyor.
        let bytes = Array(body[marker.upperBound...].utf8)
        guard count > 0, count <= bytes.count else {
            return String(body[marker.upperBound...])
        }
        return String(decoding: bytes[0..<count], as: UTF8.self)
    }

    /// Altyazı kaynağını metne çevirir; yerel dosya da uzak adres de olabilir.
    private func readSubtitle(at url: URL) async throws -> String {
        if url.isFileURL {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            // OpenSubtitles'tan gelen bazı dosyalar Latin-1/Windows-1254 oluyor.
            let data = try Data(contentsOf: url)
            for encoding in [String.Encoding.isoLatin1, .windowsCP1254, .ascii] {
                if let text = String(data: data, encoding: encoding) { return text }
            }
            throw NSError(domain: "Translation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Altyazı dosyası okunamadı"
            ])
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1254, .ascii] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw NSError(domain: "Translation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Altyazı dosyası okunamadı"
        ])
    }

    /// Çeviri dosyasını mpv'ye ekler ve **izin gerçekten açıldığını görene kadar
    /// bekler.**
    ///
    /// Önceden sabit 0,6 saniye beklenip `subtitleTracks.last` seçiliyordu. mpv
    /// büyük bir altyazıyı o sürede yükleyemezse liste hâlâ eski oluyor ve o
    /// "son iz" çevrilmemiş özgün altyazı oluyordu: çeviri %100 bitiyor, ekranda
    /// hiçbir şey değişmiyordu. Artık yeni iz kimliği belirene kadar yoklanıyor.
    @MainActor
    private func attachTranslatedSubtitle(at url: URL) async -> Int? {
        let before = Set(subtitleTracks.map(\.id))
        // Adı ve dili veriliyor: menüde "Parça 4" yerine "Türkçe · Çeviri"
        // görünüyor, ve seçim hafızası bu adla eşleşebiliyor.
        core.addSubtitleFile(url, title: "Çeviri", lang: "tur")

        for _ in 0..<40 {   // en çok ~6 saniye
            try? await Task.sleep(for: .milliseconds(150))
            refreshTracks()
            if let new = subtitleTracks.first(where: { !before.contains($0.id) }) {
                trackURLs[new.id] = url
                selectSubtitle(new)
                return new.id
            }
        }
        return nil
    }

    /// Re-selects the subtitle language the user last watched this title with, once
    /// a matching track is present. Matched by display name so it survives the
    /// track ids changing between sessions.
    private func applyPreferredSubtitle() {
        guard let want = pendingPreferredSubtitle, !want.isEmpty else { return }
        // The track's display name may carry a codec suffix ("Türkçe (Zorunlu) ·
        // WEBVTT"), so match by the track name *containing* the wanted label. This
        // is one-directional on purpose: "Türkçe (Zorunlu)" won't fall onto a plain
        // "Türkçe" track, but a plain "Türkçe" won't grab the forced one either.
        guard let match = subtitleTracks.first(where: {
            $0.displayName.localizedCaseInsensitiveContains(want)
        }) else { return }
        if selectedSubtitleID != match.id { selectSubtitle(match) }
        pendingPreferredSubtitle = nil
    }

    func toggleFullscreen() {
        isFullscreen.toggle()
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - Actions

    /// Opens a file, optionally resuming from a saved position.
    ///
    /// `title` comes from the library rather than mpv's `media-title`, because
    /// embedded title tags are frequently release-site spam.
    func open(_ url: URL,
              title: String? = nil,
              resumeAt seconds: Double = 0,
              httpHeaders: [String: String] = [:],
              subtitles: [StreamSubtitle] = [],
              resumeKey: String? = nil,
              preferredSubtitle: String? = nil) {
        isTrailer = false
        trackURLs = [:]
        didRestoreCachedTranslation = false
        currentHTTPHeaders = httpHeaders
        currentURL = url
        currentResumeKey = resumeKey
        currentTitle = title ?? url.deletingPathExtension().lastPathComponent
        position = seconds
        pendingSubtitles = subtitles
        // Saved choice wins; otherwise a stream defaults to the forced Turkish
        // track ("Türkçe (Zorunlu)") when one exists. Library files are left alone.
        if let preferredSubtitle {
            pendingPreferredSubtitle = preferredSubtitle
        } else if resumeKey != nil {
            pendingPreferredSubtitle = "Türkçe (Zorunlu)"
        } else {
            pendingPreferredSubtitle = nil
        }
        // mpv keeps `sub-delay` across files; a new file starts from the default.
        setSubtitleDelay(baseSubtitleDelay)
        core.setHTTPHeaders(httpHeaders)
        core.loadFile(url, startAt: seconds > 5 ? seconds : nil, options: Self.contentOptions(for: url))
        core.play()
    }

    /// Per-file mpv options for real content.
    ///
    /// `ytdl=no` matters: without it mpv hands every non-local URL to yt-dlp
    /// first, which for a torrent stream on 127.0.0.1 means a pointless
    /// subprocess, a failed lookup, and a misleading error in the log. Trailers
    /// are the one case that *needs* ytdl, and they go through `openTrailer`.
    private static func contentOptions(for url: URL) -> [String: String] {
        guard !url.isFileURL else { return ["ytdl": "no"] }
        return [
            "ytdl": "no",
            // A torrent stream feeds in bursts; a deeper demuxer cache rides
            // over the gaps between pieces.
            "cache": "yes",
            "demuxer-max-bytes": "128MiB",
            "demuxer-readahead-secs": "30"
        ]
    }

    /// Arama sonucundan seçilen bir YouTube videosunu oynatır.
    ///
    /// Fragmandan farkı, bunun tam uzunlukta bir film/bölüm olması: ilerleme
    /// kaydediliyor ve `resumeKey` (video kimliği) sayesinde aynı video sonra
    /// kaldığı yerden açılıyor. `ytdl=yes` şart — adresi yt-dlp çözüyor.
    func openYouTube(_ url: URL, title: String, resumeAt seconds: Double = 0,
                     resumeKey: String) {
        isTrailer = false
        trackURLs = [:]
        didRestoreCachedTranslation = false
        currentHTTPHeaders = [:]
        currentURL = url
        currentResumeKey = resumeKey
        currentTitle = title
        position = seconds
        pendingSubtitles = []
        pendingPreferredSubtitle = nil
        setSubtitleDelay(baseSubtitleDelay)
        core.setHTTPHeaders([:])
        core.loadFile(url, startAt: seconds > 5 ? seconds : nil, options: ["ytdl": "yes"])
        core.play()
    }

    /// Plays a trailer. Progress is not recorded — trailers are not library items.
    func openTrailer(_ url: URL, title: String) {
        isTrailer = true
        currentURL = url
        currentHTTPHeaders = [:]
        currentResumeKey = nil
        pendingPreferredSubtitle = nil
        currentTitle = title
        position = 0
        setSubtitleDelay(baseSubtitleDelay)
        core.setHTTPHeaders([:])
        // Fragman için en az 1080p zorunlu.
        // YouTube'da 1080p progressive (tek parça) akış bulunmuyor; mpv yt-dlp'nin
        // DASH formatını natively destekler — ayrı video+ses URL'lerini ffmpeg
        // olmadan birlikte oynatır. Bu yüzden bestvideo+bestaudio kullanılıyor.
        // Öncelik sırası: 1080p+ mp4 DASH → 1080p+ herhangi DASH → en iyi mevcut.
        core.loadFile(url, options: [
            "ytdl": "yes",
            "ytdl-format": "bestvideo[height>=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height>=1080]+bestaudio/best[height>=1080]/best"
        ])
        core.play()
    }

    /// Stops playback and returns to the library.
    func close() {
        flushProgress()
        core.command(["stop"])
        currentURL = nil
        currentHTTPHeaders = [:]
        currentResumeKey = nil
        currentTitle = ""
        position = 0
        duration = 0
        lastReportedPosition = 0
        isTrailer = false
        powerAssertion.setActive(false)
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Controls bar'ın ekranda belirmesini sağlayan kullanıcı aktivite callback'i.
    var onControlsUserActivity: (() -> Void)?

    func togglePause() {
        core.togglePause()
        updateNowPlayingInfo()
        onControlsUserActivity?()
    }

    func updateNowPlayingInfo() {
        guard currentURL != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle.isEmpty ? "ZyPlayer Video" : currentTitle
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func seek(by seconds: Double) {
        core.seek(by: seconds)
        onControlsUserActivity?()
    }

    // MARK: - Scrubbing
    //
    // Three calls rather than one setter. Firing an exact seek on every mouse move
    // is what made the bar stutter and jerk backwards: mpv queues each one, decodes
    // to the frame, and reports the *old* position in between — which then snapped
    // the thumb out from under the pointer. Now the drag only moves the displayed
    // position, mpv gets throttled keyframe seeks to keep the picture roughly in
    // step, and the one exact seek happens on release.

    /// The thumb went down: mpv's position stops driving the bar.
    func beginScrub() {
        isScrubbing = true
        scrubRelease?.cancel()
        scrubRelease = nil
    }

    /// The thumb moved. Cheap enough to call on every mouse move.
    func scrubPreview(to seconds: Double) {
        isScrubbing = true
        position = seconds
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPreviewSeek >= 0.12 else { return }
        lastPreviewSeek = now
        core.seek(to: seconds, exact: false)
    }

    /// The thumb came up: land on the frame the user actually picked.
    func endScrub(at seconds: Double) {
        position = seconds
        lastPreviewSeek = 0
        core.seek(to: seconds, exact: true)
        // mpv keeps reporting the pre-seek position for a moment; holding the lock
        // over that gap stops the bar bouncing back before the new one arrives.
        let release = DispatchWorkItem { [weak self] in self?.isScrubbing = false }
        scrubRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: release)
    }

    func setVolume(_ value: Double) {
        let clamped = max(0, min(100, value))
        volume = clamped
        core.setVolume(clamped)
        onControlsUserActivity?()
    }

    func setSpeed(_ value: Double) {
        speed = value
        core.setSpeed(value)
        onControlsUserActivity?()
    }

    private func extractEmbeddedSubtitle(from videoURL: URL, ffIndex: Int) async throws -> URL {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpegPath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw NSError(domain: "FFmpegError", code: 404, userInfo: [
                NSLocalizedDescriptionKey:
                    "Sistemde ffmpeg bulunamadı. Terminalden \"brew install ffmpeg\" ile kurabilirsin."
            ])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("extracted_\(UUID().uuidString).srt")

        // `-nostdin`: ffmpeg arka planda terminal beklemesin.
        // `-loglevel error`: yalnızca gerçek hatalar borudan aksın.
        var arguments = ["-nostdin", "-y", "-loglevel", "error"]

        let isRemote = !videoURL.isFileURL
        if isRemote {
            // Uzak kaynakta başlık taramasını kısa tutuyoruz ki indirmeyi
            // beklemeyelim. Yerel dosyada bu sınır gereksiz; hatta çok
            // akışlı bir MKV'de ffmpeg'in izleri tanımasını engelleyebilir.
            arguments += ["-analyzeduration", "100000", "-probesize", "100000"]
        }
        if isRemote, !currentHTTPHeaders.isEmpty {
            var headerLines = ""
            for (key, value) in currentHTTPHeaders {
                headerLines += "\(key): \(value)\r\n"
            }
            arguments += ["-headers", headerLines]
        }

        // ÖNEMLİ: yerel dosyalarda `absoluteString` kullanılamaz. Onda boşluk
        // "%20", Türkçe harfler "%C5%9F" olarak kodlanır; ffmpeg ise `file:`
        // yolunu çözmez, adı harfi harfine açmaya çalışır ve "No such file or
        // directory" verir. Bu yüzden dosya yolu doğrudan geçiliyor.
        let input = videoURL.isFileURL ? videoURL.path : videoURL.absoluteString
        arguments += ["-i", input]
        arguments += ["-map", "0:\(ffIndex)"]
        arguments += ["-c:s", "srt"]
        arguments += [outputURL.path]

        process.arguments = arguments

        // Boruyu okumazsak ffmpeg'in hata çıktısı tamponu doldurabilir ve süreç
        // yazmaya çalışırken kilitlenir; bu yüzden ayrı bir boru açıp sonuna
        // kadar okuyoruz.
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()

        let errorReader = Task.detached { () -> String in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        // Yerel dosyada ffmpeg, altyazı paketlerini bulmak için dosyanın
        // tamamını taramak zorunda — büyük bir filmde bu dakikayı bulabilir.
        // Eski 8 saniyelik sınır bu yüzden neredeyse her seferinde "zaman
        // aşımı" veriyordu.
        let timeout: Double = isRemote ? 45 : 300
        let timedOut = TimeoutFlag()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.mark()
            process.terminate()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // `terminationHandler` yerine `waitUntilExit`: süreç, işleyici
            // atanmadan önce biterse eski kod sonsuza dek asılı kalıyordu.
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        timeoutTask.cancel()

        let errorText = await errorReader.value
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Hatanın tamamı Console'a düşsün; ekrandaki mesaj kırpılmış oluyor.
        // (`log stream --predicate 'process == "ZyPlayer"'` ile izlenebilir.)
        if process.terminationStatus != 0 || !errorText.isEmpty {
            NSLog("ZyPlayer gömülü altyazı: durum=%d\nkomut=%@ %@\nffmpeg çıktısı:\n%@",
                  process.terminationStatus,
                  ffmpegPath, arguments.joined(separator: " "), errorText)
        }

        if timedOut.isSet {
            throw NSError(domain: "FFmpegError", code: 15, userInfo: [
                NSLocalizedDescriptionKey: isRemote
                    ? "Zaman aşımı: içerik internetten akıtıldığı için gömülü altyazı okunamadı. \"Altyazı Ara…\" menüsünden bir Türkçe altyazı indirmeyi dene."
                    : "Zaman aşımı: gömülü altyazı çıkartılamadı."
            ])
        }

        guard process.terminationStatus == 0 else {
            let detail = errorText.isEmpty
                ? "kod: \(process.terminationStatus)"
                : String(errorText.suffix(300))
            throw NSError(domain: "FFmpegError", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg gömülü altyazıyı çıkartamadı (\(detail))"
            ])
        }

        // Çıkış 0 olsa bile dosya boş kalabilir (izde hiç metin yoksa).
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw NSError(domain: "FFmpegError", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Gömülü iz boş çıktı; çevrilecek altyazı satırı yok."
            ])
        }

        return outputURL
    }
}

/// Zaman aşımı görevinden gelen işareti süreç bekleyen tarafla paylaşan
/// küçük, kilitli kutu.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock(); value = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
