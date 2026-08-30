import Foundation
import Observation
import SwiftUI

/// Only two modes on purpose: the player chrome is designed against a fixed
/// backdrop, so "follow the system" is not offered. A stored `"system"` from an
/// older build fails to decode and falls back to `.dark`.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

enum TranslationEngine: String, Codable, CaseIterable, Identifiable {
    case google, zai, nvidia, openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google (Ücretsiz, hızlı)"
        case .zai: "Z.ai / GLM (Yapay zeka)"
        case .nvidia: "NVIDIA NIM (Yapay zeka)"
        case .openRouter: "OpenRouter (Yapay zeka)"
        }
    }

    var explanation: String {
        switch self {
        case .google:
            "Anahtar istemez ve hızlıdır, ama satır satır çevirdiği için bağlamı " +
            "kaçırabilir. Google bu ücretsiz servisi çok istek gelen IP'lerde " +
            "geçici olarak engelleyebilir."
        case .zai:
            "GLM modelleriyle bağlama uygun, film tadında çeviri. Anahtar gerekir; " +
            "model Ayarlar > API Anahtarı'ndan seçilir."
        case .nvidia:
            "NVIDIA'nın build.nvidia.com üzerinden ücretsiz sunduğu güçlü " +
            "modelleri kullanır. Anahtar gerekir; ücretsiz katman kredi ile " +
            "sınırlıdır."
        case .openRouter:
            "Birçok sağlayıcının ücretsiz modeline tek anahtarla erişir. " +
            "Ücretsiz modeller sık kota/istek sınırına takılabilir, bu yüzden " +
            "seçilen model tökezlerse otomatik olarak bir sonrakine geçilir."
        }
    }
}

struct SettingsData: Codable {
    /// TMDB API Read Access Token (v4 JWT), sent as a Bearer header.
    var tmdbToken: String = ""
    /// Metadata language; TMDB falls back to English when a field is missing.
    var metadataLanguage: String = "tr-TR"
    var fetchMetadataAutomatically: Bool = true
    /// Where finished torrent downloads are written.
    var downloadDirectory: String = ""
    /// Torrent index for films and episodes alike. A setting because these
    /// addresses move.
    var torrentAPIBase: String = TorrentioClient.defaultBase
    /// Google OAuth "Desktop app" client, registered by the user.
    var googleClientID: String = ""
    var googleClientSecret: String = ""
    /// Drive folder the user picked; empty means nothing is selected yet.
    var driveFolderID: String = ""
    var driveFolderName: String = ""
    var appearance: AppearanceMode = .dark
    var subtitleStyle: SubtitleStyle = SubtitleStyle()
    /// OpenSubtitles consumer API key, registered by the user.
    var openSubtitlesKey: String = ""
    var openSubtitlesLanguages: String = "tr,en"
    /// Key-free subtitle sources, tried in order.
    var subtitleAddons: [SubtitleAddon] = [.builtIn]
    /// On/off flags for the ZyStream streaming sites. Only id + enabled are
    /// stored; the provider itself lives in `StreamRegistry`.
    var streamSources: [StreamSourceToggle] = StreamRegistry.defaultToggles
    /// Where the user last dragged the player's transport bar, as an offset from
    /// its default spot. Stored as two numbers rather than a `CGSize` so the JSON
    /// stays readable.
    var playerControlsOffsetX: Double = 0
    var playerControlsOffsetY: Double = 0
    var autoplayTrailers: Bool = true
    var translationEngine: TranslationEngine = .google
    var zaiApiKey: String = ""
    /// Kullanıcı Ayarlar > API Anahtarı'ndan değiştirebiliyor; yedek modeller
    /// için bkz. `ZaiTranslator.freeModels`.
    var zaiModel: String = ZaiTranslator.defaultModel
    /// build.nvidia.com API anahtarı (nvapi-...).
    var nvidiaApiKey: String = ""
    var nvidiaModel: String = NvidiaTranslator.defaultModel
    /// openrouter.ai API anahtarı.
    var openRouterApiKey: String = ""
    var openRouterModel: String = OpenRouterTranslator.defaultModel
    /// Arama sonuçlarına YouTube bölümü eklensin mi. Yalnızca aramayı etkiler;
    /// kapalıyken YouTube'a hiç istek gitmez.
    var youtubeSearchEnabled: Bool = true
    /// IPTV aboneliğinin bağlantı bilgileri.
    var iptvCredentials: IPTVCredentials = .empty
    /// Yalnızca Türkçe IPTV içeriği listelensin mi. Sağlayıcı kataloğunda
    /// onlarca ülkenin kanalı ve filmi var; açıkken TR dışındakiler gizleniyor.
    var iptvOnlyTurkish: Bool = true

    init(tmdbToken: String = "", metadataLanguage: String = "tr-TR",
         fetchMetadataAutomatically: Bool = true, downloadDirectory: String = "",
         googleClientID: String = "", googleClientSecret: String = "",
         driveFolderID: String = "", driveFolderName: String = "",
         appearance: AppearanceMode = .dark,
         subtitleStyle: SubtitleStyle = SubtitleStyle(),
         openSubtitlesKey: String = "", openSubtitlesLanguages: String = "tr,en",
         subtitleAddons: [SubtitleAddon] = [.builtIn],
         streamSources: [StreamSourceToggle] = StreamRegistry.defaultToggles,
         playerControlsOffsetX: Double = 0, playerControlsOffsetY: Double = 0,
         torrentAPIBase: String = TorrentioClient.defaultBase,
         autoplayTrailers: Bool = true,
         translationEngine: TranslationEngine = .google,
         zaiApiKey: String = "",
         zaiModel: String = ZaiTranslator.defaultModel,
         nvidiaApiKey: String = "",
         nvidiaModel: String = NvidiaTranslator.defaultModel,
         openRouterApiKey: String = "",
         openRouterModel: String = OpenRouterTranslator.defaultModel,
         youtubeSearchEnabled: Bool = true,
         iptvCredentials: IPTVCredentials = .empty,
         iptvOnlyTurkish: Bool = true) {
        self.iptvOnlyTurkish = iptvOnlyTurkish
        self.iptvCredentials = iptvCredentials
        self.youtubeSearchEnabled = youtubeSearchEnabled
        self.nvidiaApiKey = nvidiaApiKey
        self.nvidiaModel = nvidiaModel
        self.zaiApiKey = zaiApiKey
        self.zaiModel = zaiModel
        self.openRouterApiKey = openRouterApiKey
        self.openRouterModel = openRouterModel
        self.translationEngine = translationEngine
        self.autoplayTrailers = autoplayTrailers
        self.playerControlsOffsetX = playerControlsOffsetX
        self.playerControlsOffsetY = playerControlsOffsetY
        self.streamSources = streamSources
        self.torrentAPIBase = torrentAPIBase
        self.subtitleStyle = subtitleStyle
        self.openSubtitlesKey = openSubtitlesKey
        self.openSubtitlesLanguages = openSubtitlesLanguages
        self.subtitleAddons = subtitleAddons
        self.tmdbToken = tmdbToken
        self.metadataLanguage = metadataLanguage
        self.fetchMetadataAutomatically = fetchMetadataAutomatically
        self.downloadDirectory = downloadDirectory
        self.googleClientID = googleClientID
        self.googleClientSecret = googleClientSecret
        self.driveFolderID = driveFolderID
        self.driveFolderName = driveFolderName
        self.appearance = appearance
    }

    /// Keys that no longer have a property but are still read when an older
    /// settings file is loaded.
    private enum LegacyKeys: String, CodingKey {
        case seriesTorrentAPIBase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbToken = c.value(.tmdbToken, "")
        metadataLanguage = c.value(.metadataLanguage, "tr-TR")
        fetchMetadataAutomatically = c.value(.fetchMetadataAutomatically, true)
        downloadDirectory = c.value(.downloadDirectory, "")
        googleClientID = c.value(.googleClientID, "")
        googleClientSecret = c.value(.googleClientSecret, "")
        driveFolderID = c.value(.driveFolderID, "")
        driveFolderName = c.value(.driveFolderName, "")
        appearance = c.value(.appearance, AppearanceMode.dark)
        subtitleStyle = c.value(.subtitleStyle, SubtitleStyle())
        openSubtitlesKey = c.value(.openSubtitlesKey, "")
        openSubtitlesLanguages = c.value(.openSubtitlesLanguages, "tr,en")
        // A settings file written before addons existed has no key at all, and
        // must still come back with the built-in source rather than none.
        subtitleAddons = c.value(.subtitleAddons, [SubtitleAddon.builtIn])
        // Reconciled with the registry: providers with no saved flag (a fresh
        // install, or one added in a newer build) come back enabled, and a
        // removed provider drops out.
        streamSources = StreamRegistry.reconcile(c.value(.streamSources, []))
        playerControlsOffsetX = c.value(.playerControlsOffsetX, 0)
        playerControlsOffsetY = c.value(.playerControlsOffsetY, 0)
        autoplayTrailers = c.value(.autoplayTrailers, true)
        translationEngine = c.value(.translationEngine, TranslationEngine.google)
        zaiApiKey = c.value(.zaiApiKey, "")
        zaiModel = c.value(.zaiModel, ZaiTranslator.defaultModel)
        nvidiaApiKey = c.value(.nvidiaApiKey, "")
        nvidiaModel = c.value(.nvidiaModel, NvidiaTranslator.defaultModel)
        openRouterApiKey = c.value(.openRouterApiKey, "")
        openRouterModel = c.value(.openRouterModel, OpenRouterTranslator.defaultModel)
        // Anahtar eklenmeden önce yazılmış bir ayar dosyasında bu alan yok;
        // açık gelmesi doğru olan, kullanıcı kapatana kadar YouTube aranıyor.
        youtubeSearchEnabled = c.value(.youtubeSearchEnabled, true)
        iptvCredentials = c.value(.iptvCredentials, .empty)
        iptvOnlyTurkish = c.value(.iptvOnlyTurkish, true)
        // Migration: films used to come from YTS and had their own address,
        // with episodes on a separate one. There is one index now, so a stored
        // YTS address is replaced — by whatever the user had set for episodes if
        // they changed it, otherwise the default.
        //
        // Ayrıca Torrentio'nun `/lite/…` yolu ve eski mirror alan adları artık
        // 404/çözümsüz: kayıtlı adres bunlardan biriyse torrent araması hiç
        // sonuç döndürmez, bu yüzden sessizce varsayılana çevrilir.
        let stored = c.value(.torrentAPIBase, "")
        if stored.isEmpty
            || stored.localizedCaseInsensitiveContains("yts")
            || TorrentioClient.isDeadLegacyBase(stored) {
            torrentAPIBase = TorrentioClient.defaultBase
        } else {
            torrentAPIBase = stored
        }
    }
}

/// App-wide preferences, persisted as `settings.json`.
@Observable
final class AppSettings {
    var tmdbToken: String {
        didSet { persist() }
    }
    var metadataLanguage: String {
        didSet { persist() }
    }
    var fetchMetadataAutomatically: Bool {
        didSet { persist() }
    }
    var downloadDirectory: String {
        didSet { persist() }
    }
    var googleClientID: String {
        didSet { persist() }
    }
    var googleClientSecret: String {
        didSet { persist() }
    }
    var driveFolderID: String {
        didSet { persist() }
    }
    var driveFolderName: String {
        didSet { persist() }
    }
    var appearance: AppearanceMode {
        didSet { persist() }
    }
    var subtitleStyle: SubtitleStyle {
        didSet { persist() }
    }
    var openSubtitlesKey: String {
        didSet { persist() }
    }
    var openSubtitlesLanguages: String {
        didSet { persist() }
    }
    var subtitleAddons: [SubtitleAddon] {
        didSet { persist() }
    }
    var streamSources: [StreamSourceToggle] {
        didSet { persist() }
    }
    /// The player's transport bar comes back where the user left it.
    var playerControlsOffset: CGSize {
        didSet { persist() }
    }
    var torrentAPIBase: String {
        didSet { persist() }
    }
    var autoplayTrailers: Bool {
        didSet { persist() }
    }
    var translationEngine: TranslationEngine {
        didSet { persist() }
    }
    var zaiApiKey: String {
        didSet { persist() }
    }
    var zaiModel: String {
        didSet { persist() }
    }
    var nvidiaApiKey: String {
        didSet { persist() }
    }
    var nvidiaModel: String {
        didSet { persist() }
    }
    var openRouterApiKey: String {
        didSet { persist() }
    }
    var openRouterModel: String {
        didSet { persist() }
    }
    /// Arama sonuçlarında YouTube bölümü.
    var youtubeSearchEnabled: Bool {
        didSet { persist() }
    }
    /// IPTV aboneliği: sunucu adresi, kullanıcı adı, parola.
    var iptvCredentials: IPTVCredentials {
        didSet { persist() }
    }
    /// Yalnızca Türkçe IPTV içeriği gösterilsin mi.
    var iptvOnlyTurkish: Bool {
        didSet { persist() }
    }
    /// Falls back to the built-in address when the field is cleared, so the
    /// torrent section never silently stops working.
    var effectiveTorrentAPIBase: String {
        let trimmed = torrentAPIBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TorrentioClient.defaultBase : trimmed
    }

    var enabledSubtitleAddons: [SubtitleAddon] {
        subtitleAddons.filter(\.isEnabled)
    }

    /// The stream providers the user has switched on, built at their configured
    /// base URL.
    var enabledStreamProviders: [StreamProvider] {
        streamSources.filter(\.isEnabled).compactMap(Self.provider(for:))
    }

    /// One configured provider by id, enabled or not — used to resolve a
    /// favourited hit or load its poster.
    func streamProvider(id: String) -> StreamProvider? {
        streamSources.first { $0.id == id }.flatMap(Self.provider(for:))
    }

    private static func provider(for toggle: StreamSourceToggle) -> StreamProvider? {
        StreamRegistry.info(id: toggle.id)?.make(toggle.baseURL)
    }

    var hasEnabledStreamSources: Bool {
        streamSources.contains { $0.isEnabled && StreamRegistry.info(id: $0.id) != nil }
    }

    var hasOpenSubtitlesKey: Bool {
        !openSubtitlesKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasZaiKey: Bool {
        !zaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasNvidiaKey: Bool {
        !nvidiaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasOpenRouterKey: Bool {
        !openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var colorScheme: ColorScheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }

    @ObservationIgnored private let store = LocalStore(
        fileName: "settings.json", defaultValue: SettingsData()
    )

    init() {
        let value = store.value
        tmdbToken = value.tmdbToken
        metadataLanguage = value.metadataLanguage
        fetchMetadataAutomatically = value.fetchMetadataAutomatically
        downloadDirectory = value.downloadDirectory.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
            : value.downloadDirectory
        googleClientID = value.googleClientID
        googleClientSecret = value.googleClientSecret
        driveFolderID = value.driveFolderID
        driveFolderName = value.driveFolderName
        appearance = value.appearance
        subtitleStyle = value.subtitleStyle
        openSubtitlesKey = value.openSubtitlesKey
        openSubtitlesLanguages = value.openSubtitlesLanguages
        subtitleAddons = value.subtitleAddons
        streamSources = value.streamSources
        playerControlsOffset = CGSize(width: value.playerControlsOffsetX,
                                      height: value.playerControlsOffsetY)
        torrentAPIBase = value.torrentAPIBase
        autoplayTrailers = value.autoplayTrailers
        translationEngine = value.translationEngine
        zaiApiKey = value.zaiApiKey
        zaiModel = value.zaiModel
        nvidiaApiKey = value.nvidiaApiKey
        nvidiaModel = value.nvidiaModel
        openRouterApiKey = value.openRouterApiKey
        openRouterModel = value.openRouterModel
        youtubeSearchEnabled = value.youtubeSearchEnabled
        iptvCredentials = value.iptvCredentials
        iptvOnlyTurkish = value.iptvOnlyTurkish
    }

    var hasTMDBToken: Bool {
        !tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persist() {
        store.replace(with: SettingsData(
            tmdbToken: tmdbToken,
            metadataLanguage: metadataLanguage,
            fetchMetadataAutomatically: fetchMetadataAutomatically,
            downloadDirectory: downloadDirectory,
            googleClientID: googleClientID,
            googleClientSecret: googleClientSecret,
            driveFolderID: driveFolderID,
            driveFolderName: driveFolderName,
            appearance: appearance,
            subtitleStyle: subtitleStyle,
            openSubtitlesKey: openSubtitlesKey,
            openSubtitlesLanguages: openSubtitlesLanguages,
            subtitleAddons: subtitleAddons,
            streamSources: streamSources,
            playerControlsOffsetX: playerControlsOffset.width,
            playerControlsOffsetY: playerControlsOffset.height,
            torrentAPIBase: torrentAPIBase,
            autoplayTrailers: autoplayTrailers,
            translationEngine: translationEngine,
            zaiApiKey: zaiApiKey,
            zaiModel: zaiModel,
            nvidiaApiKey: nvidiaApiKey,
            nvidiaModel: nvidiaModel,
            openRouterApiKey: openRouterApiKey,
            openRouterModel: openRouterModel,
            youtubeSearchEnabled: youtubeSearchEnabled,
            iptvCredentials: iptvCredentials,
            iptvOnlyTurkish: iptvOnlyTurkish
        ))
    }
}
