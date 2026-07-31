import Foundation
import AppKit
import SwiftUI
import GameController
import Observation

/// PlayStation 5 (DualSense) ve Oyun Kontrolcü Yöneticisi.
@Observable
final class GamepadManager: @unchecked Sendable {
    static let shared = GamepadManager()

    var isConnected = false
    var controllerName: String = ""
    var showConnectionToast = false
    var toastMessage: String = ""
    private var toastTask: Task<Void, Never>?

    weak var activePlayer: PlayerModel?
    var onClosePlayer: (() -> Void)?
    var onGlobalBack: (() -> Void)?
    var onGlobalSearch: (() -> Void)?

    private init() {}

    func start(onGlobalBack: @escaping () -> Void, onGlobalSearch: @escaping () -> Void) {
        self.onGlobalBack = onGlobalBack
        self.onGlobalSearch = onGlobalSearch

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        GCController.startWirelessControllerDiscovery()
        checkExistingControllers()
    }

    func setPlayer(_ player: PlayerModel?, onClose: (() -> Void)?) {
        self.activePlayer = player
        self.onClosePlayer = onClose
    }

    private func checkExistingControllers() {
        if let first = GCController.controllers().first {
            registerController(first)
        }
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            registerController(controller)
        }
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.showToast("🎮 Kontrolcü Bağlantısı Kesildi")
        }
    }

    private func registerController(_ controller: GCController) {
        let name = controller.vendorName ?? "PlayStation Kontrolcüsü"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.controllerName = name
            self.showToast("🎮 \(name) Bağlandı")
        }

        // Extended Gamepad (PS5 DualSense / DualShock / Xbox / MFi)
        if let extended = controller.extendedGamepad {
            // ❌ Cross (A Button) -> OK / Play-Pause
            extended.buttonA.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleCrossButton() }
            }

            // ⭕ Circle (B Button) -> Geri / Kapat
            extended.buttonB.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleCircleButton() }
            }

            // 🔳 Square (X Button) -> Altyazı / Menü
            extended.buttonX.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleSquareButton() }
            }

            // 📐 Triangle (Y Button) -> Arama
            extended.buttonY.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleTriangleButton() }
            }

            // L1 (Left Shoulder) -> 10sn Geri Sar
            extended.leftShoulder.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleL1Button() }
            }

            // R1 (Right Shoulder) -> 10sn İleri Sar
            extended.rightShoulder.valueChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.handleR1Button() }
            }

            // D-Pad Yön Tuşları
            extended.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                self?.handleDPad(x: xValue, y: yValue)
            }

            // Sol Analog Stick
            extended.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
                if abs(xValue) > 0.6 || abs(yValue) > 0.6 {
                    self?.handleDPad(x: xValue, y: yValue)
                }
            }
        }
    }

    // MARK: - Actions
    private func handleCrossButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let player = self.activePlayer {
                player.togglePause()
            } else {
                self.postKeyEvent(keyCode: 36) // Return
            }
        }
    }

    private func handleCircleButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.activePlayer != nil {
                self.onClosePlayer?()
            } else {
                self.onGlobalBack?()
            }
        }
    }

    private func handleSquareButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let player = self.activePlayer {
                player.selectSubtitle(
                    player.selectedSubtitleID == nil ? player.subtitleTracks.first : nil
                )
            }
        }
    }

    private func handleTriangleButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let player = self.activePlayer {
                player.toggleFullscreen()
            } else {
                self.onGlobalSearch?()
            }
        }
    }

    private func handleL1Button() {
        DispatchQueue.main.async { [weak self] in
            self?.activePlayer?.seek(by: -10)
        }
    }

    private func handleR1Button() {
        DispatchQueue.main.async { [weak self] in
            self?.activePlayer?.seek(by: 10)
        }
    }

    private var lastDPadTime: Date = .distantPast

    private func handleDPad(x: Float, y: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastDPadTime) > 0.18 else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            if let player = self.activePlayer {
                if x > 0.5 { self.lastDPadTime = now; player.seek(by: 10) }
                else if x < -0.5 { self.lastDPadTime = now; player.seek(by: -10) }
                else if y > 0.5 { self.lastDPadTime = now; player.setVolume(min(100, player.volume + 5)) }
                else if y < -0.5 { self.lastDPadTime = now; player.setVolume(max(0, player.volume - 5)) }
            } else {
                if x > 0.5 { self.lastDPadTime = now; self.postKeyEvent(keyCode: 124) }      // Sağ Ok
                else if x < -0.5 { self.lastDPadTime = now; self.postKeyEvent(keyCode: 123) } // Sol Ok
                else if y > 0.5 { self.lastDPadTime = now; self.postKeyEvent(keyCode: 126) }  // Yukarı Ok
                else if y < -0.5 { self.lastDPadTime = now; self.postKeyEvent(keyCode: 125) } // Aşağı Ok
            }
        }
    }

    private func postKeyEvent(keyCode: UInt16) {
        guard let window = NSApp.keyWindow else { return }
        if let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) {
            window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) {
            window.sendEvent(up)
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toastMessage = text
        withAnimation(.spring(duration: 0.3)) {
            showConnectionToast = true
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.4)) {
                    self.showConnectionToast = false
                }
            }
        }
    }
}
