import Foundation
import AppKit
import MediaPlayer

/// Bluetooth Kumanda / Klavye Sürücüsü.
///
/// macOS üzerinde Bluetooth Klavye olarak bağlanan kumandalar (Huayu RC-BT1846 vb.)
/// HİÇBİR macOS izni (Accessibility / Input Monitoring) GEREKTİRMEDEN
/// NSEvent.addLocalMonitorForEvents altyapısıyla dinlenir.
final class BluetoothRemoteManager: @unchecked Sendable {
    static let shared = BluetoothRemoteManager()

    private var localMonitor: Any?
    private var lastToggleTime: Date = .distantPast

    weak var activePlayer: PlayerModel?
    var onClosePlayer: (() -> Void)?
    var onGlobalBack: (() -> Void)?
    var onGlobalSearch: (() -> Void)?

    private init() {}

    /// Çift sinyal tetiklenmesini (Karabiner + MPRemoteCommandCenter çakışmasını) önlemek için 0.25sn debounce korumalı toggle.
    func togglePauseWithDebounce() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.25 else { return }
        lastToggleTime = now
        activePlayer?.togglePause()
    }

    func startGlobal(onGlobalBack: @escaping () -> Void, onGlobalSearch: @escaping () -> Void) {
        self.onGlobalBack = onGlobalBack
        self.onGlobalSearch = onGlobalSearch

        if localMonitor == nil {
            setupLocalMonitor()
            setupMPRemoteCommandCenter()
        }
    }

    func setPlayer(_ player: PlayerModel?, onClose: (() -> Void)?) {
        self.activePlayer = player
        self.onClosePlayer = onClose
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    // MARK: - Local NSEvent Monitor (İzinsiz, Ön Plan Klavye / Kumanda Dinleyici)
    private func setupLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self else { return event }

            let isPlayerOpen = (self.activePlayer != nil)

            // 1. System Defined (Donanım Medya Tuşları: Play/Pause, Next, Prev)
            if event.type == .systemDefined && event.subtype.rawValue == 8 {
                let keyCode = Int32(event.data1) >> 16 & 0xFF
                let keyFlags = (event.data1 & 0x0000FFFF)
                let keyDown = (((keyFlags & 0xFF00) >> 8) & 0x1) == 0

                if keyDown {
                    if self.activePlayer != nil {
                        switch keyCode {
                        case 16, 100: // Play / Pause (NX_KEYTYPE_PLAY)
                            self.togglePauseWithDebounce()
                            return nil
                        case 0: // Sound Up (Ses Artır)
                            if let p = self.activePlayer { p.setVolume(min(100, p.volume + 5)) }
                            return nil
                        case 1: // Sound Down (Ses Azalt)
                            if let p = self.activePlayer { p.setVolume(max(0, p.volume - 5)) }
                            return nil
                        case 17, 19, 9: // Next / Fast Forward
                            self.activePlayer?.seek(by: 10)
                            return nil
                        case 18, 20, 10: // Prev / Rewind
                            self.activePlayer?.seek(by: -10)
                            return nil
                        case 7: // Mute
                            if let p = self.activePlayer { p.setVolume(p.volume > 0 ? 0 : 100) }
                            return nil
                        default:
                            break
                        }
                    } else {
                        if keyCode == 16 || keyCode == 100 {
                            self.simulateSelectClick()
                            return nil
                        }
                    }
                }
            }

            // 2. Normal Klavye / Kumanda Olayları (.keyDown)
            if event.type == .keyDown {
                // Metin yazılan her bağlamda — oynatıcı açık olsun ya da
                // olmasın — tuş olduğu gibi geçer. Bu kontrol eskiden yalnızca
                // aşağıdaki menü dalında yapılıyordu; oynatıcı açıkken altyazı
                // arama kutusuna basılan backspace harf silmek yerine oynatıcıyı
                // kapatıyor, boşluk oynatmayı duraklatıyordu.
                if KeyboardContext.isTyping { return event }

                if isPlayerOpen {
                    // ── PLAYER (OYNATICI) MODU ──
                    switch event.keyCode {
                    case 36, 76, 49, 65: // Return, Keypad Enter, Space, Numpad Enter (OK / Oynat-Duraklat)
                        self.togglePauseWithDebounce()
                        return nil
                    case 123: // Sol Ok (10sn Geri Sar)
                        self.activePlayer?.seek(by: -10)
                        return nil
                    case 124: // Sağ Ok (10sn İleri Sar)
                        self.activePlayer?.seek(by: 10)
                        return nil
                    case 126: // Yukarı Ok (Ses Artır)
                        if let p = self.activePlayer { p.setVolume(min(100, p.volume + 5)) }
                        return nil
                    case 125: // Aşağı Ok (Ses Azalt)
                        if let p = self.activePlayer { p.setVolume(max(0, p.volume - 5)) }
                        return nil
                    case 53, 51, 115, 117, 2: // Escape, Backspace, Home, End, 'd' (Karabiner ac_back)
                        self.onClosePlayer?()
                        return nil
                    case 3: // 'f' tuşu (Tam Ekran)
                        self.activePlayer?.toggleFullscreen()
                        return nil
                    default:
                        break
                    }
                } else {
                    // ── ANA MENÜ / ARAYÜZ MODU ──
                    // Yazma bağlamı yukarıda elendi; buraya gelen tuş kısayoldur.
                    switch event.keyCode {
                    case 53, 51, 115, 2: // Escape, Backspace, Home, 'd' (Karabiner ac_back -> Geri Dön)
                        self.onGlobalBack?()
                        return nil
                    case 3: // 'f' (Karabiner ac_search -> Arama)
                        self.onGlobalSearch?()
                        return nil
                    case 36, 76, 65: // Return / Enter (OK Seçim Tuşu)
                        self.simulateSelectClick()
                        return nil
                    default:
                        return event
                    }
                }
            }

            return event
        }
    }

    // MARK: - MPRemoteCommandCenter
    private func setupMPRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.activePlayer != nil {
                    self?.togglePauseWithDebounce()
                } else {
                    self?.simulateSelectClick()
                }
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePauseWithDebounce() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePauseWithDebounce() }
            return .success
        }
    }

    func simulateSelectClick() {
        guard let window = NSApp.keyWindow else { return }
        if let responder = window.firstResponder as? NSButton {
            responder.performClick(nil)
        } else if let responder = window.firstResponder as? NSControl {
            window.makeFirstResponder(responder)
        }
    }

}
