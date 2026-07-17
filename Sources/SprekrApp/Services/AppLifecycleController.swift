import AppKit
import Combine
import Foundation
import ServiceManagement
import SprekrCore
import SwiftUI

/// SwiftUI's hosting view otherwise uses AppKit's default inactive-window
/// behavior, where the first click may only activate the window. Accepting the
/// first mouse makes navigation respond on the click the user actually made.
final class SprekrFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SprekrHostingController<Content: View>: NSViewController {
    private let rootView: Content

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = SprekrFirstMouseHostingView(rootView: rootView)
    }
}

enum AppAppearanceResolver {
    static func appearanceName(for choice: AppearanceChoice) -> NSAppearance.Name? {
        switch choice {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    static func appearance(for choice: AppearanceChoice) -> NSAppearance? {
        appearanceName(for: choice).flatMap(NSAppearance.init(named:))
    }
}

@MainActor
final class AppLifecycleController: NSObject, ObservableObject {
    private static let launchAtLoginRebrandMigrationKey = "sprekr.launch-at-login-path-migration.v1"
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var launchedQuietly = false
    private var requestedDockVisibility = true

    var onShowApp: (() -> Void)?
    var onToggleDictation: (() -> Void)?
    var onWillTerminate: (() -> Void)?

    func configure(quietLaunch: Bool) {
        guard statusItem == nil else { return }
        prepareForInitialLaunch(quietLaunch: quietLaunch, showInDock: requestedDockVisibility)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sprekr")
        item.button?.imagePosition = .imageOnly
        item.menu = makeMenu()
        statusItem = item
    }

    func attach(window: NSWindow?) {
        mainWindow = window
    }

    func showMainWindow() {
        prepareToShowMainWindow()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            onShowApp?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyDockVisibility(_ showInDock: Bool) {
        requestedDockVisibility = showInDock
        applyEffectiveDockVisibility()
    }

    /// AppKit owns the app window, Settings scene, menu-bar UI, and Flow Bar.
    /// Driving appearance once at the application level prevents a stale
    /// SwiftUI preferredColorScheme from surviving Light/Dark → System.
    func applyAppearance(_ choice: AppearanceChoice) {
        NSApp.appearance = AppAppearanceResolver.appearance(for: choice)
    }

    /// Set presentation policy as soon as the initial Apple event is known.
    /// This runs before asynchronous bootstrap work, preventing a Dock icon
    /// flash during a quiet login-item launch.
    func prepareForInitialLaunch(quietLaunch: Bool, showInDock: Bool) {
        launchedQuietly = quietLaunch
        requestedDockVisibility = showInDock
        applyEffectiveDockVisibility()
    }

    /// A login-item launch should remain in the background until the user
    /// explicitly asks for the main window. Once revealed, honour the saved
    /// Dock preference for the rest of this process lifetime.
    func prepareToShowMainWindow() {
        guard launchedQuietly else { return }
        launchedQuietly = false
        applyEffectiveDockVisibility()
    }

    func applyLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Settings presents the actual system state rather than logging user configuration.
        }
    }

    /// `SMAppService.mainApp` can retain the old on-disk bundle location even
    /// though the stable bundle identifier did not change. Refresh the app-owned
    /// registration once after the rename, without changing the saved setting.
    func migrateLaunchAtLoginForRebrandIfNeeded(_ enabled: Bool) {
        guard #available(macOS 13.0, *), enabled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.launchAtLoginRebrandMigrationKey) else {
            applyLaunchAtLogin(true)
            return
        }

        do {
            if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: Self.launchAtLoginRebrandMigrationKey)
        } catch {
            // Leave the migration flag unset so a later launch can retry.
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed() -> Bool { false }

    func applicationWillTerminate() {
        onWillTerminate?()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Sprekr", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "Start or Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sprekr", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func openApp() { showMainWindow() }
    @objc private func toggleDictation() { onToggleDictation?() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func applyEffectiveDockVisibility() {
        NSApp.setActivationPolicy(requestedDockVisibility && !launchedQuietly ? .regular : .accessory)
    }
}

/// Keeps the main workspace comfortably wide without assuming one fixed display size.
/// The minimum is deliberately screen-relative: a half-screen tile is too narrow for
/// the persistent navigation rail plus the editable workspace.
struct MainWindowGeometry: Equatable {
    let initialContentSize: NSSize
    let minimumContentSize: NSSize

    static func resolve(visibleFrame: NSRect) -> MainWindowGeometry {
        let horizontalBreathingRoom: CGFloat = 32
        let verticalBreathingRoom: CGFloat = 32
        let availableWidth = max(480, visibleFrame.width - horizontalBreathingRoom)
        let availableHeight = max(480, visibleFrame.height - verticalBreathingRoom)

        let initialWidth = min(
            availableWidth,
            max(1_080, visibleFrame.width * 0.88)
        )
        let minimumWidth = min(
            initialWidth,
            max(960, visibleFrame.width * 0.70)
        )
        let initialHeight = min(720, availableHeight)
        let minimumHeight = min(650, initialHeight)

        return MainWindowGeometry(
            initialContentSize: NSSize(width: initialWidth, height: initialHeight),
            minimumContentSize: NSSize(width: minimumWidth, height: minimumHeight)
        )
    }
}

@MainActor
final class SprekrAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = SprekrAppController()
    weak var lifecycle: AppLifecycleController?
    private var mainWindowController: NSWindowController?
    private var mainWindowMinimumFrameSize = NSSize(width: 0, height: 0)
    private var isCorrectingMainWindowFrame = false
    private var isTerminating = false

    override init() {
        super.init()
        controller.lifecycle.onShowApp = { [weak self] in self?.showMainWindow() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        controller.lifecycle.applyAppearance(controller.settings.values.appearance)

        // Set the bundled artwork explicitly instead of relying only on the
        // LaunchServices icon cache. Local development builds reuse one bundle
        // identifier and are re-signed frequently, which can otherwise leave
        // an older Dock tile visible after the app bundle has been replaced.
        if let iconURL = Bundle.main.url(forResource: "SprekrIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // SMAppService owns the deliberate login launch. Disable App Resume's
        // separate relaunch mechanism so it cannot restore an old main window
        // on top of that quiet background launch.
        NSApp.disableRelaunchOnLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchContext = InitialLaunchContext.classify(
            initialAppleEvent: NSAppleEventManager.shared().currentAppleEvent
        )
        controller.lifecycle.prepareForInitialLaunch(
            quietLaunch: launchContext.startsQuietly,
            showInDock: controller.settings.values.showInDock
        )
        // Install the agent synchronously. `boot` repeats this call later,
        // but `configure` is idempotent and will not reapply quiet mode after
        // a user has already reopened the app.
        controller.lifecycle.configure(quietLaunch: launchContext.startsQuietly)

        if !launchContext.startsQuietly {
            showMainWindow()
        }

        Task { [weak self] in
            guard let self else { return }
            await controller.boot(delegate: self, quietLaunch: launchContext.startsQuietly)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        controller.lifecycle.applicationShouldTerminateAfterLastWindowClosed()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.lifecycle.applicationWillTerminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isTerminating else { return true }
        // Closing the visible window must not quit the menu-bar agent.
        sender.orderOut(nil)
        return false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === mainWindowController?.window else { return frameSize }
        return NSSize(
            width: max(frameSize.width, mainWindowMinimumFrameSize.width),
            height: max(frameSize.height, mainWindowMinimumFrameSize.height)
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === mainWindowController?.window,
              !isCorrectingMainWindowFrame else { return }
        correctMainWindowFrameIfNeeded(window, display: true)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === mainWindowController?.window else { return }
        applySizingPolicy(to: window, for: window.screen)
        correctMainWindowFrameIfNeeded(window, display: true)
    }

    private func showMainWindow() {
        controller.lifecycle.prepareToShowMainWindow()
        let window = makeMainWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindow() -> NSWindow {
        if let window = mainWindowController?.window { return window }

        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let geometry = MainWindowGeometry.resolve(visibleFrame: visibleFrame)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: geometry.initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sprekr"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = SprekrHostingController(rootView: RootView(controller: controller))
        window.delegate = self

        mainWindowController = NSWindowController(window: window)
        applySizingPolicy(to: window, for: targetScreen)

        let frameName = NSWindow.FrameAutosaveName(
            SprekrIdentity.Compatibility.legacyWindowFrameName
        )
        let restoredSavedFrame = window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)

        if restoredSavedFrame {
            applySizingPolicy(to: window, for: window.screen ?? targetScreen)
            correctMainWindowFrameIfNeeded(window, display: false)
        } else {
            window.center()
        }

        controller.lifecycle.attach(window: window)
        return window
    }

    private func applySizingPolicy(to window: NSWindow, for screen: NSScreen?) {
        let visibleFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let geometry = MainWindowGeometry.resolve(visibleFrame: visibleFrame)

        window.contentMinSize = geometry.minimumContentSize
        mainWindowMinimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: geometry.minimumContentSize)
        ).size

        // AppKit documents that minSize/contentMinSize can be ignored when Auto
        // Layout owns the content view. The window delegate enforces this same
        // value during live resize, while minSize still helps native tiling UI.
        window.minSize = mainWindowMinimumFrameSize
    }

    private func correctMainWindowFrameIfNeeded(_ window: NSWindow, display: Bool) {
        let current = window.frame
        let correctedSize = NSSize(
            width: max(current.width, mainWindowMinimumFrameSize.width),
            height: max(current.height, mainWindowMinimumFrameSize.height)
        )
        guard correctedSize != current.size else { return }

        var corrected = current
        corrected.size = correctedSize
        corrected.origin.y = current.maxY - correctedSize.height

        if let screen = window.screen ?? NSScreen.main {
            corrected.origin.x = min(
                max(corrected.origin.x, screen.visibleFrame.minX),
                screen.visibleFrame.maxX - corrected.width
            )
            corrected.origin.y = min(
                max(corrected.origin.y, screen.visibleFrame.minY),
                screen.visibleFrame.maxY - corrected.height
            )
        }

        isCorrectingMainWindowFrame = true
        window.setFrame(corrected, display: display)
        isCorrectingMainWindowFrame = false
    }
}
