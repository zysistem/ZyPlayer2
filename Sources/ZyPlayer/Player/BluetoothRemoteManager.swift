import Foundation
import AppKit
import IOKit
import IOKit.hid
import MediaPlayer

/// Google Chromecast / Bluetooth Kumanda (Huayu RC-BT1846 vb.) Donanım ve HID Sürücüsü.
///
/// macOS varsayılanda Bluetooth Android/Chromecast kumandalarını sıradan HID aygıtı olarak görür.
/// IOHIDManager aracılığıyla ham HID raporları dinlenerek kumandanın D-Pad (Yön tuşları),
/// OK / Select tuşu, Back (Geri), Home, Play/Pause ve Medya tuşları doğrudan yakalanır.
final class BluetoothRemoteManager: @unchecked Sendable {
    static let shared = BluetoothRemoteManager()

    private var hidManager: IOHIDManager?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    weak var activePlayer: PlayerModel?
    var onClosePlayer: (() -> Void)?

    private init() {}

    func start(player: PlayerModel, onClose: @escaping () -> Void) {
        self.activePlayer = player
        self.onClosePlayer = onClose

        setupIOHIDManager()
        setupNSEventMonitors()
        setupMPRemoteCommandCenter()
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

        // Input Value Callback
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
            guard let self, let player = self.activePlayer else { return }

            // ── Consumer Control (Medya / Kumanda Tuşları) Page 0x0C ──
            if usagePage == 0x0C {
                switch usage {
                case 0xCD: // Play / Pause Toggle
                    player.togglePause()
                case 0xB0: // Play
                    if player.isPaused { player.togglePause() }
                case 0xB1: // Pause
                    if !player.isPaused { player.togglePause() }
                case 0xB5: // Scan Next / Next Track
                    player.seek(by: 30)
                case 0xB6: // Scan Previous / Previous Track
                    player.seek(by: -30)
                case 0xB7: // Stop
                    self.onClosePlayer?()
                case 0xE9: // Volume Increment
                    player.setVolume(min(100, player.volume + 5))
                case 0xEA: // Volume Decrement
                    player.setVolume(max(0, player.volume - 5))
                case 0xE2: // Mute
                    player.setVolume(player.volume > 0 ? 0 : 100)
                case 0x221, 0x223: // AC Search / Home / Spotlight (Siyah tuş)
                    player.togglePause()
                case 0x224: // AC Back
                    self.onClosePlayer?()
                default:
                    break
                }
            }
            // ── Generic Desktop Page 0x01 (D-Pad Yön Tuşları vb.) ──
            else if usagePage == 0x01 {
                switch usage {
                case 0x89: // D-Pad Up
                    player.setVolume(min(100, player.volume + 5))
                case 0x8A: // D-Pad Down
                    player.setVolume(max(0, player.volume - 5))
                case 0x8B: // D-Pad Right
                    player.seek(by: 10)
                case 0x8C: // D-Pad Left
                    player.seek(by: -10)
                case 0x8D: // D-Pad Select / OK
                    player.togglePause()
                default:
                    break
                }
            }
        }
    }

    // MARK: - 2. NSEvent Monitoring (Klavye, D-Pad ve Medya Kısayolları)
    private func setupNSEventMonitors() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, let player = self.activePlayer else { return event }

            // System Defined (Medya Tuşları)
            if event.type == .systemDefined && event.subtype.rawValue == 8 {
                let keyCode = Int32(event.data1) >> 16 & 0xFF
                let keyFlags = (event.data1 & 0x0000FFFF)
                let keyDown = (((keyFlags & 0xFF00) >> 8) & 0x1) == 0

                if keyDown {
                    switch keyCode {
                    case 16, 0, 100: // Play/Pause
                        player.togglePause()
                        return nil
                    case 17: // Next
                        player.seek(by: 30)
                        return nil
                    case 18: // Previous
                        player.seek(by: -30)
                        return nil
                    case 19, 9: // Fast Forward
                        player.seek(by: 10)
                        return nil
                    case 20, 10: // Rewind
                        player.seek(by: -10)
                        return nil
                    default:
                        break
                    }
                }
            }

            // Normal Klavye Olayları (.keyDown)
            if event.type == .keyDown {
                // Metin kutusu aktifse karıştırma
                if self.isTypingContext() { return event }

                switch event.keyCode {
                case 36, 76, 49, 65: // Return, Keypad Enter, Space, Numpad Enter (OK Tuşu)
                    player.togglePause()
                    return nil
                case 123: // Sol Ok (Rewind)
                    player.seek(by: -10)
                    return nil
                case 124: // Sağ Ok (Fast Forward)
                    player.seek(by: 10)
                    return nil
                case 126: // Yukarı Ok (Ses +)
                    player.setVolume(min(100, player.volume + 5))
                    return nil
                case 125: // Aşağı Ok (Ses -)
                    player.setVolume(max(0, player.volume - 5))
                    return nil
                case 53, 51, 115, 117: // Esc, Backspace, Home, End (Geri Tuşu)
                    self.onClosePlayer?()
                    return nil
                default:
                    break
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
            Task { @MainActor in self?.activePlayer?.togglePause() }
            return .success
        }

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.activePlayer?.isPaused == true { self?.activePlayer?.togglePause() } }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.activePlayer?.isPaused == false { self?.activePlayer?.togglePause() } }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.activePlayer?.seek(by: 30) }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.activePlayer?.seek(by: -30) }
            return .success
        }
    }

    private func isTypingContext() -> Bool {
        // Oynatıcı açıkken hiçbir klavye/kumanda tuşunu engelleme
        if activePlayer != nil { return false }

        guard let window = NSApp.keyWindow else { return false }
        if window.sheets.isEmpty == false { return true }
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }
        if let textView = responder as? NSTextView, textView.isFieldEditor { return true }
        return false
    }
}
