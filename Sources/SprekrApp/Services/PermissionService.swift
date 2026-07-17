import ApplicationServices
import AVFoundation
import AppKit
import Foundation

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    func refresh() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophone() async -> Bool {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: granted = false
        @unknown default: granted = false
        }
        refresh()
        return granted
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()
    }

    func openPrivacySettings(_ pane: PrivacyPane) {
        let suffix: String
        switch pane {
        case .microphone: suffix = "Privacy_Microphone"
        case .accessibility: suffix = "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }

    enum PrivacyPane {
        case microphone
        case accessibility
    }
}
