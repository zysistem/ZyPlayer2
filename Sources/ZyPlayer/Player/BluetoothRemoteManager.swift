import Foundation
import AppKit
import IOKit
import IOKit.hid
import MediaPlayer

/// Google Chromecast / Bluetooth Kumanda (Huayu RC-BT1846 vb.) Donanım ve HID Sürücüsü.
///
/// Kumanda macOS tarafından Bluetooth Klavye olarak algılanır.
/// Hem video oynatıcı (Player) modunda hem de Ana Menü / Arayüz gezinmesinde
/// D-Pad (Yön tuşları), OK (Enter/Space), Geri (Back/Escape) ve Medya tuşlarını destekler.
final class BluetoothRemoteManager: @unchecked Sendable {
    static let shared = BluetoothRemoteManager()

    private var hidManager: IOHIDManager?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    weak var activePlayer: PlayerModel?
    var onClosePlayer: (() -> Void)?
    var onGlobalBack: (() -> Void)?
    var onGlobalSearch: (() -> Void)?

    private init() {}

    func startGlobal(onGlobalBack: @escaping () -> Void, onGlobalSearch: @escaping () -> Void) {
        self.onGlobalBack = onGlobalBack
        self.onGlobalSearch = onGlobalSearch

        if hidManager == nil {
            setupIOHIDManager()
            setupNSEventMonitors()
            setupMPRemoteCommandCenter()
        }
    }

    func setPlayer(_ player: PlayerModel?, onClose: (() -> Void)?) {
        self.activePlayer = player
        self.onClosePlayer = onClose
    }

    func stop() {
        if let hidManager {
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil

        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    // MARK: - 1. IOKit IOHIDManager (Ham Bluetooth HID Tuşlarını Yakalama)
    private func setupIOHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        // Consumer Controls (0x0C) ve Generic Desktop (0x01) HID cihazlarını eşleştir
        let criteria: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: 0x0C,
                kIOHIDDeviceUsageKey as String: 0x01
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x01
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
            guard let context = context else { return }
            let this = Unmanaged<BluetoothRemoteManager>.fromOpaque(context).takeUnretainedValue()
            this.handleHIDValue(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)

        // Sadece Tuşa basılma anı (Button Down / Value > 0)
        guard integerValue > 0 else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let player = self.activePlayer {
                // ── Player Açıkken Oynatıcı Kontrolleri ──
                if usagePage == 0x0C {
                    switch usage {
                    case 0xCD, 0xB0, 0xB1: player.togglePause()
                    case 0xB5, 0x8B: player.seek(by: 10)
                    case 0xB6, 0x8C: player.seek(by: -10)
                    case 0xB7, 0x224: self.onClosePlayer?()
                    case 0xE9, 0x89: player.setVolume(min(100, player.volume + 5))
                    case 0xEA, 0x8A: player.setVolume(max(0, player.volume - 5))
                    case 0xE2: player.setVolume(player.volume > 0 ? 0 : 100)
                    case 0x221, 0x223: player.togglePause()
                    default: break
                    }
                } else if usagePage == 0x01 {
                    switch usage {
                    case 0x89: player.setVolume(min(100, player.volume + 5))
                    case 0x8A: player.setVolume(max(0, player.volume - 5))
                    case 0x8B: player.seek(by: 10)
                    case 0x8C: player.seek(by: -10)
                    case 0x8D: player.togglePause()
                    default: break
                    }
                }
            } else {
                // ── Player Kapalıyken Ana Menü / Arayüz Kontrolleri ──
                if usagePage == 0x0C {
                    switch usage {
                    case 0x224, 0xB7: self.onGlobalBack?()
                    case 0x221, 0x223: self.onGlobalSearch?()
                    case 0xCD, 0xB0, 0x8D: self.simulateSelectClick()
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - 2. NSEvent Monitoring (Klavye, D-Pad ve Medya Kısayolları)
    private func setupNSEventMonitors() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }

            let isPlayerOpen = (self.activePlayer != nil)

            // System Defined (Medya Tuşları)
            if event.type == .systemDefined && event.subtype.rawValue == 8 {
                let keyCode = Int32(event.data1) >> 16 & 0xFF
                let keyFlags = (event.data1 & 0x0000FFFF)
                let keyDown = (((keyFlags & 0xFF00) >> 8) & 0x1) == 0

                if keyDown {
                    if let player = self.activePlayer {
                        switch keyCode {
                        case 16, 0, 100: player.togglePause(); return nil
                        case 17, 19, 9: player.seek(by: 10); return nil
                        case 18, 20, 10: player.seek(by: -10); return nil
                        default: break
                        }
                    } else {
                        if keyCode == 16 || keyCode == 0 {
                            self.simulateSelectClick()
                            return nil
                        }
                    }
                }
            }

            // Normal Klavye Olayları (.keyDown)
            if event.type == .keyDown {
                if isPlayerOpen {
                    // ── Player Modu ──
                    switch event.keyCode {
                    case 36, 76, 49, 65: // OK / Enter / Space
                        self.activePlayer?.togglePause()
                        return nil
                    case 123: // Sol (Geri sar)
                        self.activePlayer?.seek(by: -10)
                        return nil
                    case 124: // Sağ (İleri sar)
                        self.activePlayer?.seek(by: 10)
                        return nil
                    case 126: // Yukarı (Ses +)
                        if let p = self.activePlayer { p.setVolume(min(100, p.volume + 5)) }
                        return nil
                    case 125: // Aşağı (Ses -)
                        if let p = self.activePlayer { p.setVolume(max(0, p.volume - 5)) }
                        return nil
                    case 53, 51, 115, 117: // Back / Esc / Home
                        self.onClosePlayer?()
                        return nil
                    default:
                        break
                    }
                } else {
                    // ── Ana Menü / Arayüz Modu ──
                    // Metin yazılıyorsa sadece yön ve geri tuşlarına müdahale et
                    let typing = self.isTypingContext()

                    switch event.keyCode {
                    case 53, 51, 115, 117: // Geri / Escape / Backspace / Home
                        if !typing {
                            self.onGlobalBack?()
                            return nil
                        }
                    case 36, 76, 65: // Return / Enter (OK Tuşu)
                        if !typing {
                            self.simulateSelectClick()
                            return nil
                        }
                    default:
                        break
                    }
                }
            }

            return event
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined], handler: handler)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .systemDefined]) { event in
            _ = handler(event)
        }
    }

    // MARK: - 3. MPRemoteCommandCenter (macOS Donanım Medya Kontrol Merkezi)
    private func setupMPRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let player = self?.activePlayer {
                    player.togglePause()
                } else {
                    self?.simulateSelectClick()
                }
            }
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.activePlayer?.togglePause() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.activePlayer?.togglePause() }
            return .success
        }
    }

    /// OK / Select tuşuna basıldığında odaktaki elemana tıklama simülasyonu
    private func simulateSelectClick() {
        guard let window = NSApp.keyWindow else { return }
        if let responder = window.firstResponder as? NSButton {
            responder.performClick(nil)
        } else if let responder = window.firstResponder as? NSControl {
            window.makeFirstResponder(responder)
        }
    }

    private func isTypingContext() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.sheets.isEmpty == false { return true }
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if let textView = responder as? NSTextView, textView.isFieldEditor { return true }
        return false
    }
}

