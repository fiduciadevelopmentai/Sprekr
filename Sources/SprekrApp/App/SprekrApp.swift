import AppKit
import SwiftUI

@main
struct SprekrApp: App {
    @NSApplicationDelegateAdaptor(SprekrAppDelegate.self) private var delegate

    var body: some Scene {
        // The AppKit delegate owns the main window. A `WindowGroup` would
        // eagerly create a window even when SMAppService starts the app at
        // login, making a truly quiet launch impossible.
        Settings {
            SettingsView(controller: delegate.controller)
                .frame(minWidth: 620, minHeight: 650)
                .font(SprekrTypography.body())
                .scrollIndicators(.never)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Start or Stop Dictation") { delegate.controller.toggleDictation() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var controller: SprekrAppController

    var body: some View {
        Group {
            if controller.settings.values.onboardingCompleted {
                MainShellView(controller: controller)
            } else {
                OnboardingView(controller: controller)
            }
        }
        .font(SprekrTypography.body())
        .tint(SprekrPalette.accent)
        .scrollIndicators(.never)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.applicationDidBecomeActive()
        }
    }
}
