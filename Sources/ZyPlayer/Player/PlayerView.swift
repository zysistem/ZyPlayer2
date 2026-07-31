import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Hosts the single, long-lived `MPVGLView` owned by the model.
struct VideoSurface: NSViewRepresentable {
    let renderer: MPVGLView

    func makeNSView(context: Context) -> MPVGLView { renderer }

    func updateNSView(_ nsView: MPVGLView, context: Context) {}
}

/// Where the user dragged the control bar, relative to its default spot.
///
/// A reference type on purpose: dragging must not touch `PlayerView`'s own
/// state, or every mouse move would rebuild the video surface, the title bar and
/// the whole transport bar. Only `MovingLayer` reads this, so only it redraws.
@Observable
final class ControlBarPosition {
    var offset: CGSize = .zero
}

/// Applies the live control-bar offset. `content` is a stored view value rather
/// than a `@ViewBuilder` closure, so SwiftUI reuses it untouched while the offset
/// changes — that is what keeps the drag smooth.
private struct MovingLayer<Content: View>: View {
    let position: ControlBarPosition
    let content: Content

    var body: some View {
        content.offset(position.offset)
    }
}

/// Player'ın sağ üstündeki bölüm seçicinin verisi.
///
/// Kaynağı ne olursa olsun (kütüphanedeki dosyalar ya da bir akış sitesinin
/// bölüm listesi) player aynı düz listeyi görüyor: her satırın sezon/bölüm
/// numarası, adı ve kendini oynatan bir kapanışı var.
struct PlayerEpisodeList {
    struct Entry: Identifiable {
        let id: String
        let season: Int
        let episode: Int
        let title: String?
        /// Şu an oynayan bölüm — listede vurgulanıyor.
        let isCurrent: Bool
        /// Sonuna kadar izlenmiş bölüm — listede tikle işaretleniyor.
        let isWatched: Bool
        let play: () -> Void

        /// "S2B7" — sezon/bölüm kısa kodu.
        var code: String { "S\(season)B\(episode)" }
    }

    let showTitle: String
    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    var seasons: [Int] {
        Array(Set(entries.map(\.season))).sorted()
    }

    func entries(inSeason season: Int) -> [Entry] {
        entries.filter { $0.season == season }.sorted { $0.episode < $1.episode }
    }

    var current: Entry? { entries.first(where: \.isCurrent) }
}

/// The player screen: video surface with frosted-glass controls above it.
struct PlayerView: View {
    @Bindable var model: PlayerModel
    let settings: AppSettings
    var onClose: () -> Void = {}
    var onSearchSubtitles: (() -> Void)?
    /// Dizi izlerken önceki/sonraki bölüm. Bölüm yoksa (film ya da serinin ucu)
    /// nil gelir ve düğme hiç görünmez.
    var onPreviousEpisode: (() -> Void)?
    var onNextEpisode: (() -> Void)?
    /// Oynayan içerik bir diziyse bölüm listesi; film ise nil ve seçici çıkmaz.
    var episodes: PlayerEpisodeList?

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var barPosition = ControlBarPosition()
    @State private var showSubtitleSync = false
    /// Bölüm listesi açıkken kontroller kendiliğinden gizlenmiyor — gizlenirse
    /// listeyi taşıyan üst çubukla birlikte liste de kapanırdı.
    @State private var showEpisodes = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(renderer: model.renderer)
                .ignoresSafeArea()

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if showSubtitleSync {
                        MovingLayer(
                            position: barPosition,
                            content: SubtitleSyncPanel(model: model, onClose: {
                                withAnimation(.easeOut(duration: 0.15)) { showSubtitleSync = false }
                            })
                            .padding(.bottom, 10)
                        )
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    MovingLayer(
                        position: barPosition,
                        content: PlayerControls(
                            model: model,
                            settings: settings,
                            position: barPosition,
                            showSubtitleSync: $showSubtitleSync,
                            onSearchSubtitles: onSearchSubtitles,
                            onPreviousEpisode: onPreviousEpisode,
                            onNextEpisode: onNextEpisode,
                            onMoved: { settings.playerControlsOffset = $0 }
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    )
                }
                .transition(.opacity)
            }
            
            if model.isTranslatingSubtitles || model.translationMessage != nil {
                VStack(spacing: 16) {
                    if model.isTranslatingSubtitles {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24))
                            .foregroundStyle(.orange)
                    }
                    Text(model.translationMessage ?? "Altyazı çeviriliyor...")
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                }
                .frame(width: 320, height: 140)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onTapGesture { model.togglePause() }
        .onAppear {
            // The bar comes back wherever it was left, across launches.
            barPosition.offset = settings.playerControlsOffset
            // Kayıtlı çeviri aranırken hangi motorun çevirisi yeğlensin.
            model.restoreEngineHint = settings.translationEngine
            revealControls()
            BluetoothRemoteManager.shared.start(player: model, onClose: onClose)
        }
        .onDisappear {
            hideTask?.cancel()
            BluetoothRemoteManager.shared.stop()
            NSCursor.unhide()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassButton(systemImage: "chevron.left", action: onClose)

            Text(model.currentTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 6)

            Spacer()

            // Dizi izlerken sağ üstte bölüm seçici; filmde hiç görünmez.
            if let episodes, !episodes.isEmpty {
                EpisodePickerButton(list: episodes, isPresented: $showEpisodes)
            }
        }
        .padding(24)
    }

    private func revealControls() {
        // Guarded: this runs on every mouse move, and animating a value that is
        // already true costs a transaction for nothing.
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        // Any movement brings the pointer back; the hide below re-arms it.
        NSCursor.unhide()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !model.isPaused, !showEpisodes else { return }
            withAnimation(.easeIn(duration: 0.4)) { controlsVisible = false }
            // Self-balancing: AppKit restores the pointer on the next move, so
            // this cannot leave the cursor stuck hidden.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// One player means one monitor; a `@State` reference type would be wrapped in a
/// Binding and could not be called directly.
private let playerKeyMonitor = PlayerKeyMonitor()

/// Circular frosted button used around the player chrome.
struct GlassButton: View {
    let systemImage: String
    var font: Font = .headline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Player'ın sağ üstündeki bölüm seçici: buzlu bir düğme ve açılan liste.
///
/// Menü yerine popover: yüzlerce bölümü olan diziler bir açılır menüde
/// kullanılamıyor, burada sezon şeridi ve kaydırılabilir liste var. Liste açıkken
/// `isPresented` dışarı da bildiriliyor, çünkü kontroller gizlenirse popover'ı
/// taşıyan düğme de ekrandan kalkar.
struct EpisodePickerButton: View {
    let list: PlayerEpisodeList
    @Binding var isPresented: Bool

    /// Kullanıcının listede gezindiği sezon; açılışta oynayan bölümünki.
    @State private var season: Int?

    var body: some View {
        Button {
            season = list.current?.season ?? list.seasons.first
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
                Text(list.current?.code ?? "Bölümler")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Bölüm seç")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EpisodePickerList(
                list: list,
                season: Binding(
                    get: { season ?? list.current?.season ?? list.seasons.first ?? 1 },
                    set: { season = $0 }
                ),
                onPick: { entry in
                    isPresented = false
                    entry.play()
                }
            )
        }
    }
}

/// Popover içeriği: sezon şeridi ve o sezonun bölümleri.
private struct EpisodePickerList: View {
    let list: PlayerEpisodeList
    @Binding var season: Int
    let onPick: (PlayerEpisodeList.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(list.showTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // Tek sezonluk dizide şerit yalnızca yer kaplardı.
            if list.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(list.seasons, id: \.self) { number in
                            seasonChip(number)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 10)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(list.entries(inSeason: season)) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
                .onAppear {
                    // Liste oynayan bölümün üstünde açılsın.
                    if let current = list.current, current.season == season {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private func seasonChip(_ number: Int) -> some View {
        let isSelected = number == season
        return Button {
            season = number
        } label: {
            Text("\(number). Sezon")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(.quaternary))
                )
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func row(_ entry: PlayerEpisodeList.Entry) -> some View {
        Button {
            onPick(entry)
        } label: {
            HStack(spacing: 10) {
                Text("\(entry.episode)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entry.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 26, alignment: .trailing)

                Text(entry.title?.isEmpty == false ? entry.title! : "\(entry.episode). Bölüm")
                    .font(.system(size: 12, weight: entry.isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if entry.isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tint)
                }
                if entry.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(entry.isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
        }
        .buttonStyle(.plain)
        // Tıklanan satırın çevresine AppKit'in çizdiği mavi odak halkası,
        // listedeki vurguyla çakışıp kirli duruyordu.
        .focusEffectDisabled()
    }
}

/// Compact frosted transport bar. A grip on the left moves it anywhere in the
/// window; the drag lives on the grip rather than the whole bar so it cannot
/// fight the scrubber.
struct PlayerControls: View {
    @Bindable var model: PlayerModel
    let settings: AppSettings
    let position: ControlBarPosition
    @Binding var showSubtitleSync: Bool
    var onSearchSubtitles: (() -> Void)?
    var onPreviousEpisode: (() -> Void)?
    var onNextEpisode: (() -> Void)?
    /// Called when a drag settles, so the spot can be saved.
    var onMoved: ((CGSize) -> Void)?

    /// Where the bar sat when the current drag began; nil while not dragging.
    @State private var dragStart: CGSize?

    var body: some View {
        HStack(spacing: 14) {
            grip

            IconButton(systemImage: model.isPaused ? "play.fill" : "pause.fill", size: 15) {
                model.togglePause()
            }
            IconButton(systemImage: "gobackward.10") { model.seek(by: -10) }
            IconButton(systemImage: "goforward.10") { model.seek(by: 10) }

            // Bölüm geçişleri yalnızca bir dizi bölümü oynarken beliriyor.
            if onPreviousEpisode != nil || onNextEpisode != nil {
                Divider()
                    .frame(height: 18)
                    .overlay(Color.white.opacity(0.15))
                IconButton(systemImage: "backward.end.fill", size: 12) { onPreviousEpisode?() }
                    .disabled(onPreviousEpisode == nil)
                    .opacity(onPreviousEpisode == nil ? 0.3 : 1)
                    .help("Önceki bölüm")
                IconButton(systemImage: "forward.end.fill", size: 12) { onNextEpisode?() }
                    .disabled(onNextEpisode == nil)
                    .opacity(onNextEpisode == nil ? 0.3 : 1)
                    .help("Sonraki bölüm")
            }

            // Its own view on purpose: the position ticks four times a second, and
            // reading it here would rebuild the menus and the glass with it.
            ScrubberBar(model: model)

            volume
            audioMenu
            subtitleMenu
            speedMenu
            IconButton(systemImage: "arrow.up.left.and.arrow.down.right") {
                model.toggleFullscreen()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .frame(maxWidth: 880)
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: 16, height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // The offset is written, never read, in this body — so
                        // moving the bar does not invalidate the bar itself.
                        let base = dragStart ?? position.offset
                        if dragStart == nil { dragStart = base }
                        position.offset = CGSize(
                            width: base.width + value.translation.width,
                            height: base.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onMoved?(position.offset)
                    }
            )
            .onTapGesture(count: 2) {
                // Double-click the grip to snap back to the default position.
                position.offset = .zero
                dragStart = nil
                onMoved?(.zero)
            }
            .help("Sürükleyerek taşı, çift tıklayarak sıfırla")
    }

    private var volume: some View {
        HStack(spacing: 5) {
            Image(systemName: model.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
            Slider(
                value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                in: 0...100
            )
            .tint(.white)
            .controlSize(.mini)
            .frame(width: 62)
        }
    }

    private var audioMenu: some View {
        Menu {
            if model.audioTracks.isEmpty {
                Text("Ses parçası yok")
            }
            ForEach(model.audioTracks) { track in
                Button {
                    model.selectAudio(track)
                } label: {
                    Label(
                        track.displayName,
                        systemImage: model.selectedAudioID == track.id ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "waveform")
        }
        .menuStyle(GlassMenuStyle())
        .help("Ses dili")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                model.selectSubtitle(nil)
            } label: {
                Label("Kapalı", systemImage: model.selectedSubtitleID == nil ? "checkmark" : "")
            }

            if !model.subtitleTracks.isEmpty { Divider() }
            ForEach(model.subtitleTracks) { track in
                Button {
                    model.selectSubtitle(track)
                } label: {
                    Label(
                        track.displayName,
                        systemImage: model.selectedSubtitleID == track.id ? "checkmark" : ""
                    )
                }
            }

            if let selectedID = model.selectedSubtitleID,
               let _ = model.subtitleTracks.first(where: { $0.id == selectedID }) {
                Divider()
                Button {
                    Task {
                        await model.translateSelectedSubtitle(
                            engine: settings.translationEngine,
                            zaiApiKey: settings.zaiApiKey,
                            openRouterApiKey: settings.openRouterApiKey,
                            openRouterModel: settings.openRouterModel
                        )
                    }
                } label: {
                    Label("Seçili Altyazıyı Türkçeye Çevir", systemImage: "character.book.closed")
                }
            }

            Divider()
            // Sync gets its own panel: a menu closes on every click, which makes
            // nudging the offset a line at a time unusable.
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showSubtitleSync.toggle() }
            } label: {
                Label(
                    model.subtitleDelay == 0
                        ? "Senkron Ayarı…"
                        : "Senkron Ayarı… (\(model.subtitleDelay.asSubtitleOffset))",
                    systemImage: showSubtitleSync ? "checkmark" : ""
                )
            }
            Button("Senkronu Geri Al") { model.resetSubtitleDelay() }
                .disabled(model.subtitleDelay == 0)

            Divider()
            Button("Altyazı Ara…") { onSearchSubtitles?() }
            Button("Altyazı Dosyası Aç…") { chooseSubtitleFile() }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuStyle(GlassMenuStyle())
        .help("Altyazı")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    model.setSpeed(rate)
                } label: {
                    Label(
                        rate == 1.0 ? "Normal" : "\(rate.formatted())x",
                        systemImage: abs(model.speed - rate) < 0.01 ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Image(systemName: "speedometer")
        }
        .menuStyle(GlassMenuStyle())
        .help("Oynatma hızı")
    }

    private func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"),
                                     UTType(filenameExtension: "ass"),
                                     UTType(filenameExtension: "ssa"),
                                     UTType(filenameExtension: "sub"),
                                     UTType(filenameExtension: "vtt")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addSubtitleFile(url)
    }
}

/// Elapsed time, the seek slider and the running time.
///
/// Split out of `PlayerControls` for two reasons. The position updates four times
/// a second and continuously while dragging, and anything reading it is rebuilt
/// with it — here that is three small views instead of the entire bar. And while
/// the thumb is held, the slider is driven by `dragValue` rather than the model,
/// so a position arriving late from mpv can never yank it out from under the
/// pointer.
private struct ScrubberBar: View {
    @Bindable var model: PlayerModel

    /// Non-nil while the thumb is held down.
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(model.duration, 1)
        let shown = min(dragValue ?? model.position, duration)

        HStack(spacing: 8) {
            Text(shown.asTimecode)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { shown },
                    set: { newValue in
                        dragValue = newValue
                        model.scrubPreview(to: newValue)
                    }
                ),
                in: 0...duration,
                onEditingChanged: { isEditing in
                    if isEditing {
                        model.beginScrub()
                    } else {
                        model.endScrub(at: dragValue ?? model.position)
                        dragValue = nil
                    }
                }
            )
            .tint(.white)
            .controlSize(.mini)

            Text(model.duration.asTimecode)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 42, alignment: .leading)
        }
    }
}

/// Subtitle sync HUD: shifts the subtitles earlier or later while watching.
///
/// The offset is live state on the model rather than a saved setting — being out
/// of sync is a property of one file, so leaving the player forgets it.
struct SubtitleSyncPanel: View {
    @Bindable var model: PlayerModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Altyazı Senkronu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 16)
                IconButton(systemImage: "xmark", size: 10, action: onClose)
            }

            HStack(spacing: 10) {
                step(-1.0, label: "−1 sn")
                step(-0.1, label: "−0,1")

                Text(model.subtitleDelay.asSubtitleOffset)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 88)
                    .contentTransition(.numericText())

                step(0.1, label: "+0,1")
                step(1.0, label: "+1 sn")
            }

            HStack(spacing: 10) {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))

                Spacer(minLength: 12)

                Button("Sıfırla") {
                    withAnimation(.easeOut(duration: 0.15)) { model.resetSubtitleDelay() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(model.subtitleDelay == 0 ? 0.3 : 0.9))
                .disabled(model.subtitleDelay == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }

    private var hint: String {
        if model.subtitleDelay < 0 { return "Altyazı videodan önce görünüyor" }
        if model.subtitleDelay > 0 { return "Altyazı videodan sonra görünüyor" }
        return "Altyazı video ile aynı anda"
    }

    private func step(_ amount: Double, label: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { model.shiftSubtitleDelay(by: amount) }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 54, height: 26)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(amount < 0 ? "Altyazıyı geri al" : "Altyazıyı ileri al")
    }
}

/// Plain icon button — the bar itself carries the glass, so the buttons stay flat.
struct IconButton: View {
    let systemImage: String
    var size: CGFloat = 13
    /// The clickable square around the glyph. The transport bar passes a bigger
    /// one; the subtitle-sync HUD keeps the compact default.
    var box: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Matches the transport bar's `IconButton` so menu triggers sit flush in it.
struct GlassMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
    }
}

import MediaPlayer

/// Routes playback keys with a local event monitor and MPRemoteCommandCenter for Bluetooth remotes.
final class PlayerKeyMonitor {
    private var monitor: Any?
    private var systemMonitor: Any?

    func start(
        model: PlayerModel,
        onClose: @escaping () -> Void,
        onKeyInteraction: @escaping () -> Void,
        onPreviousEpisode: (() -> Void)? = nil,
        onNextEpisode: (() -> Void)? = nil
    ) {
        stop()

        // 1. Hardware Bluetooth Media Remote commands via macOS MPRemoteCommandCenter
        setupRemoteCommandCenter(
            model: model,
            onPreviousEpisode: onPreviousEpisode,
            onNextEpisode: onNextEpisode
        )

        // 2. Local Key Event Monitor for Keyboard / HID Remote Events
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { event in
            onKeyInteraction()

            // ── Bluetooth / Medya Tuşları (.systemDefined) ──
            if event.type == .systemDefined {
                let subtype = event.subtype.rawValue
                if subtype == 8 { // Aux control buttons (Media keys)
                    let keyCode = Int32(event.data1) >> 16 & 0xFF
                    let keyFlags = (event.data1 & 0x0000FFFF)
                    let keyDown = (((keyFlags & 0xFF00) >> 8) & 0x1) == 0

                    if keyDown {
                        switch keyCode {
                        case 16, 0, 100: // Play/Pause (Toggle)
                            model.togglePause()
                            return nil
                        case 17: // Next
                            if let next = onNextEpisode { next() } else { model.seek(by: 30) }
                            return nil
                        case 18: // Previous
                            if let prev = onPreviousEpisode { prev() } else { model.seek(by: -30) }
                            return nil
                        case 19, 9: // Fast Forward / Fast
                            model.seek(by: 10)
                            return nil
                        case 20, 10: // Rewind
                            model.seek(by: -10)
                            return nil
                        case 7: // Mute
                            model.setVolume(model.volume > 0 ? 0 : 100)
                            return nil
                        default:
                            break
                        }
                    }
                }
            }

            // Typing context / Text fields check
            if Self.isTypingContext() { return event }

            // Skip when standard command shortcuts are used (except standalone keys)
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                return event
            }

            switch event.keyCode {
            // OK / Select / Play-Pause Button
            case 36, 76, 49, 65: // Return, Keypad Enter, Space, Numpad Enter
                model.togglePause()
                return nil

            // Directional D-Pad (Sol / Sağ)
            case 123: // Left Arrow
                model.seek(by: -10)
                return nil
            case 124: // Right Arrow
                model.seek(by: 10)
                return nil

            // Directional D-Pad (Yukarı / Aşağı -> Ses)
            case 126: // Up Arrow
                model.setVolume(min(100, model.volume + 5))
                return nil
            case 125: // Down Arrow
                model.setVolume(max(0, model.volume - 5))
                return nil

            // Fullscreen
            case 3: // 'f' key
                model.toggleFullscreen()
                return nil

            // Back / Exit / Escape / Home
            case 53, 51, 115, 117: // Esc, Backspace/Delete, Home, End
                onClose()
                return nil

            // Subtitle toggle & sync
            case 1: // 's' key
                model.selectSubtitle(
                    model.selectedSubtitleID == nil ? model.subtitleTracks.first : nil
                )
                return nil
            case 6: // 'z'
                model.shiftSubtitleDelay(by: -0.1)
                return nil
            case 7: // 'x'
                model.shiftSubtitleDelay(by: 0.1)
                return nil
            case 8: // 'c'
                model.resetSubtitleDelay()
                return nil

            default:
                return event
            }
        }
    }

    private func setupRemoteCommandCenter(
        model: PlayerModel,
        onPreviousEpisode: (() -> Void)?,
        onNextEpisode: (() -> Void)?
    ) {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in model.togglePause() }
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in
            Task { @MainActor in if model.isPaused { model.togglePause() } }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in if !model.isPaused { model.togglePause() } }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in
                if let next = onNextEpisode { next() } else { model.seek(by: 30) }
            }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in
                if let prev = onPreviousEpisode { prev() } else { model.seek(by: -30) }
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in model.seek(by: 10) }
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in model.seek(by: -10) }
            return .success
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil

        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
    }

    private static func isTypingContext() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.sheets.isEmpty == false { return true }
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if let textView = responder as? NSTextView, textView.isFieldEditor { return true }
        return false
    }

    deinit { stop() }
}

extension Double {
    /// Signed subtitle offset, e.g. `+0,4 sn` / `0,0 sn`.
    var asSubtitleOffset: String {
        let sign = self > 0 ? "+" : self < 0 ? "−" : ""
        return String(format: "%@%.1f sn", sign, abs(self))
            .replacingOccurrences(of: ".", with: ",")
    }

    /// `1:23:45` / `04:12` style timecode.
    var asTimecode: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
