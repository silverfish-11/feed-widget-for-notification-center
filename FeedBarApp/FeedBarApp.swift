import Cocoa
import ServiceManagement
import WidgetKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = FeedSettings()
    private lazy var scraper = ScraperManager(settings: settings)
    private var preferences = WidgetPreferences()
    private var preferencesNotice: String?
    private var settingsWindow: SettingsWindowController?
    private var loginNotice: String?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "FeedBar")
        scraper.onUpdate = { [weak self] in self?.rebuildMenu() }
        loadPreferences()
        configureLoginItem()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, self.settings.automaticallyRefreshes else { return }
                self.scraper.scrapeAll()
            }
        }
        rebuildMenu()
        scraper.startTimer()
    }
    private func rebuildMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Feed in Notification Center", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        addItem("Refresh Now", action: #selector(refresh), to: menu, key: "r")
        menu.addItem(.separator())
        for (key, title) in [("x", "X"), ("ig", "Instagram")] {
            let source = scraper.snapshot.sources[key] ?? FeedSourceState()
            let detail = source.message.isEmpty ? "Not connected" : source.message
            let item = NSMenuItem(title: "\(title): \(detail)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        addItem("Open X / Sign In…", action: #selector(loginX), to: menu)
        addItem("Open Instagram / Sign In…", action: #selector(loginIG), to: menu)
        if let notice = scraper.storageError ?? loginNotice {
            let item = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem("Preferences…", action: #selector(showPreferences), to: menu, key: ",")
        addItem("Quit FeedBar", action: #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
        updatePreferencesWindow()
    }
    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc private func refresh() { scraper.scrapeAll() }
    private func login(_ key: String) { scraper.showLogin(key: key, title: key == "x" ? "X — FeedBar" : "Instagram — FeedBar") }
    @objc private func loginX() { login("x") }
    @objc private func loginIG() { login("ig") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showPreferences() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onRefreshMinutesChange = { [weak self] minutes in
                guard let self else { return }
                self.settings.refreshMinutes = minutes
                self.scraper.rescheduleTimer()
                self.updatePreferencesWindow()
            }
            controller.onPreferencesChange = { [weak self] value in self?.savePreferences(value) }
            controller.onLaunchAtLoginChange = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
            controller.onOpenSource = { [weak self] key in self?.login(key) }
            controller.onRefresh = { [weak self] in self?.refresh() }
            controller.onOpenLoginSettings = { SMAppService.openSystemSettingsLoginItems() }
            controller.onActivation = { [weak self] in
                self?.loadPreferences()
                self?.updatePreferencesWindow()
            }
            settingsWindow = controller
        }
        loadPreferences()
        updatePreferencesWindow()
        settingsWindow?.present()
    }

    private func loadPreferences() {
        do {
            preferences = try WidgetPreferences.load()
            preferencesNotice = nil
        } catch {
            preferencesNotice = "Widget preferences could not be read. Your saved feed is unchanged."
        }
    }

    private func savePreferences(_ change: (inout WidgetPreferences) -> Void) {
        do {
            preferences = try WidgetPreferences.update(change)
            preferencesNotice = nil
            WidgetCenter.shared.reloadTimelines(ofKind: FeedBarConstants.widgetKind)
        } catch {
            preferencesNotice = "Preferences could not be saved. Please try again."
        }
        updatePreferencesWindow()
    }

    private func updatePreferencesWindow() {
        guard let settingsWindow else { return }
        let status = SMAppService.mainApp.status
        let approvalNotice = status == .requiresApproval
            ? "Allow FeedBar under System Settings → General → Login Items." : nil
        let notice = [preferencesNotice, scraper.storageError, loginNotice, approvalNotice]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: "\n")
        settingsWindow.update(refreshMinutes: settings.refreshMinutes, preferences: preferences,
                              loginEnabled: status == .enabled || status == .requiresApproval,
                              snapshot: scraper.snapshot, notice: notice.isEmpty ? nil : notice)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(true, forKey: "feedbar_v2_login_configured")
            loginNotice = nil
        } catch {
            loginNotice = "Could not update Start at Login: \(error.localizedDescription)"
        }
        rebuildMenu()
    }
    private func configureLoginItem() {
        // A widget's collector must survive login/restarts. Register once; respect
        // later changes made in the menu or System Settings.
        guard !UserDefaults.standard.bool(forKey: "feedbar_v2_login_configured") else { return }
        do {
            if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: "feedbar_v2_login_configured")
            if SMAppService.mainApp.status == .requiresApproval {
                loginNotice = nil // Read pending approval from the live service status.
            }
        } catch {
            loginNotice = "Start at Login could not be enabled. Open Preferences to retry."
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        scraper.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "feedbar" {
                if url.host == "settings" { showPreferences() }
                else if url.host == "login", let key = url.pathComponents.last, ["x", "ig"].contains(key) { login(key) }
                // Older widget timelines may still contain feedbar://open.
                // Both routes refresh the background collector without a feed window.
                else if url.host == "refresh" || url.host == "open" { refresh() }
            } else if url.scheme == "https", let host = url.host?.lowercased(),
                      ["x.com", "www.x.com", "instagram.com", "www.instagram.com"].contains(host),
                      url.user == nil, url.password == nil {
                // WidgetKit may deliver a post Link to the containing application.
                NSWorkspace.shared.open(url)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The feed lives exclusively in the Notification Center widget.
        // Authentication windows are opened only by explicit sign-in actions.
        refresh()
        return false
    }
}

@main
enum FeedBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
