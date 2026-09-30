import Cocoa

/// A single preferences window; the feed itself stays in Notification Center.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onRefreshMinutesChange: ((Int) -> Void)?
    var onPreferencesChange: ((WidgetPreferences) -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onOpenSource: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenLoginSettings: (() -> Void)?
    var onActivation: (() -> Void)?

    private let tabs = NSSegmentedControl(labels: ["General", "Appearance", "Accounts"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshPicker = NSPopUpButton()
    private let appearancePicker = NSPopUpButton()
    private let textPicker = NSPopUpButton()
    private let densityPicker = NSPopUpButton()
    private let fitPicker = NSPopUpButton()
    private let loginToggle = NSButton(checkboxWithTitle: "Start FeedBar at login", target: nil, action: nil)
    private let mediaToggle = NSButton(checkboxWithTitle: "Show photos and video previews", target: nil, action: nil)
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabels = ["x": NSTextField(wrappingLabelWithString: "Not connected"),
                                "ig": NSTextField(wrappingLabelWithString: "Not connected")]
    private var pages: [NSView] = []
    private var preferences = WidgetPreferences()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FeedBar Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        makeContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(refreshMinutes: Int, preferences: WidgetPreferences, loginEnabled: Bool,
                snapshot: FeedSnapshot, notice: String?) {
        self.preferences = preferences
        refreshPicker.selectItem(withTag: refreshMinutes)
        appearancePicker.selectItem(at: WidgetPreferences.Appearance.allCases.firstIndex(of: preferences.appearance) ?? 0)
        textPicker.selectItem(at: WidgetPreferences.TextSize.allCases.firstIndex(of: preferences.textSize) ?? 1)
        densityPicker.selectItem(at: WidgetPreferences.Density.allCases.firstIndex(of: preferences.density) ?? 0)
        fitPicker.selectItem(at: WidgetPreferences.ImageFit.allCases.firstIndex(of: preferences.imageFit) ?? 1)
        mediaToggle.state = preferences.showsMedia ? .on : .off
        fitPicker.isEnabled = preferences.showsMedia
        loginToggle.state = loginEnabled ? .on : .off
        noticeLabel.stringValue = notice ?? ""
        for (key, label) in sourceLabels {
            let source = snapshot.sources[key] ?? FeedSourceState()
            label.stringValue = source.message.isEmpty ? "Not connected" : source.message
        }
        switch preferences.appearance {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func makeContent() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Preferences")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = note("Feed in Notification Center")
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.setAccessibilityIdentifier("settings.tabs")

        for minutes in FeedSettings.refreshOptions {
            refreshPicker.addItem(withTitle: minutes == 0 ? "Manually" : "Every \(minutes) minutes")
            refreshPicker.lastItem?.tag = minutes
        }
        configure(refreshPicker, action: #selector(changeRefresh), identifier: "settings.refresh")
        configure(appearancePicker, titles: WidgetPreferences.Appearance.allCases.map {
            switch $0 { case .system: return "System"; case .light: return "Light"; case .dark: return "Dark" }
        }, action: #selector(changeAppearance), identifier: "settings.appearance")
        configure(textPicker, titles: WidgetPreferences.TextSize.allCases.map {
            switch $0 { case .small: return "Small"; case .standard: return "Standard"; case .large: return "Large" }
        }, action: #selector(changeText), identifier: "settings.text-size")
        configure(densityPicker, titles: WidgetPreferences.Density.allCases.map {
            $0 == .comfortable ? "Comfortable" : "Compact"
        }, action: #selector(changeDensity), identifier: "settings.density")
        configure(fitPicker, titles: WidgetPreferences.ImageFit.allCases.map {
            $0 == .fit ? "Fit entire image" : "Fill preview"
        }, action: #selector(changeFit), identifier: "settings.image-fit")
        loginToggle.target = self
        loginToggle.action = #selector(changeLogin)
        loginToggle.setAccessibilityIdentifier("settings.start-at-login")
        mediaToggle.target = self
        mediaToggle.action = #selector(changeMedia)
        mediaToggle.setAccessibilityIdentifier("settings.show-media")
        let loginSettings = button("Open Login Items…", action: #selector(openLoginSettings))
        let general = stack([
            row("Refresh feed", control: refreshPicker),
            note("Manual mode refreshes only when you request it or finish signing in. An active refresh can finish."),
            loginToggle,
            loginSettings,
            button("Refresh Now", action: #selector(refreshNow)),
            note("macOS controls when fresh posts appear in the widget.")
        ], spacing: 13)
        let appearance = stack([
            row("Appearance", control: appearancePicker),
            row("Text size", control: textPicker),
            row("Feed density", control: densityPicker),
            mediaToggle,
            row("Image framing", control: fitPicker),
            note("Changes save automatically. Smaller widgets and larger text may show fewer posts. macOS widget styling can affect appearance.")
        ], spacing: 13)
        let accounts = stack([
            accountRow("X", key: "x", action: #selector(openX)),
            separator(),
            accountRow("Instagram", key: "ig", action: #selector(openInstagram)),
            note("Sign in using the source’s website. Close its window when you’re done to refresh the feed.")
        ], spacing: 18)
        pages = [general, appearance, accounts]
        let pageContainer = NSView()
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor)
            ])
        }
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 3
        noticeLabel.setAccessibilityIdentifier("settings.notice")
        let layout = stack([heading, subtitle, tabs, pageContainer, noticeLabel], spacing: 12)
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            pageContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            tabs.widthAnchor.constraint(equalTo: layout.widthAnchor),
            noticeLabel.heightAnchor.constraint(equalToConstant: 40)
        ])
        selectTab()
    }

    private func configure(_ picker: NSPopUpButton, titles: [String] = [], action: Selector, identifier: String) {
        picker.addItems(withTitles: titles)
        picker.target = self
        picker.action = action
        picker.setAccessibilityIdentifier(identifier)
        picker.widthAnchor.constraint(equalToConstant: 184).isActive = true
    }

    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        control.setAccessibilityLabel(title)
        let spacer = NSView()
        let view = NSStackView(views: [label, spacer, control])
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 12
        return view
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = spacing
        for view in views {
            view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        }
        return result
    }

    private func accountRow(_ title: String, key: String, action: Selector) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let status = sourceLabels[key]!
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        let details = stack([name, status], spacing: 4)
        let open = button("Open / Sign In…", action: action)
        open.setAccessibilityLabel("Open \(title) or sign in")
        let result = NSStackView(views: [details, open])
        result.orientation = .horizontal
        result.alignment = .top
        result.spacing = 16
        open.setContentHuggingPriority(.required, for: .horizontal)
        open.widthAnchor.constraint(equalToConstant: 152).isActive = true
        details.widthAnchor.constraint(equalTo: result.widthAnchor, constant: -168).isActive = true
        return result
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func selectTab() {
        for (index, page) in pages.enumerated() { page.isHidden = index != tabs.selectedSegment }
    }
    @objc private func changeRefresh() { onRefreshMinutesChange?(refreshPicker.selectedItem?.tag ?? 5) }
    @objc private func changeLogin() { onLaunchAtLoginChange?(loginToggle.state == .on) }
    @objc private func refreshNow() { onRefresh?() }
    @objc private func openLoginSettings() { onOpenLoginSettings?() }
    @objc private func openX() { onOpenSource?("x") }
    @objc private func openInstagram() { onOpenSource?("ig") }
    @objc private func changeAppearance() {
        preferences.appearance = WidgetPreferences.Appearance.allCases[appearancePicker.indexOfSelectedItem]
        onPreferencesChange?(preferences)
    }
    @objc private func changeText() {
        preferences.textSize = WidgetPreferences.TextSize.allCases[textPicker.indexOfSelectedItem]
        onPreferencesChange?(preferences)
    }
    @objc private func changeDensity() {
        preferences.density = WidgetPreferences.Density.allCases[densityPicker.indexOfSelectedItem]
        onPreferencesChange?(preferences)
    }
    @objc private func changeFit() {
        preferences.imageFit = WidgetPreferences.ImageFit.allCases[fitPicker.indexOfSelectedItem]
        onPreferencesChange?(preferences)
    }
    @objc private func changeMedia() {
        preferences.showsMedia = mediaToggle.state == .on
        onPreferencesChange?(preferences)
    }
    func windowDidBecomeKey(_ notification: Notification) { onActivation?() }
}
