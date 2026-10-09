import AppKit
import ImageIO
import RotationCore
import AppleWallpaper
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: AppCoordinator
    private let setPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let locationLabel = NSTextField(wrappingLabelWithString: "")
    private let transitionsLabel = NSTextField(wrappingLabelWithString: "")
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private let loginToggle = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let rotationButton = NSButton(title: "Enable Rotation", target: nil, action: nil)
    private let verificationButton = NSButton(title: "Verify on This Mac…", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Previous Setup…", target: nil, action: nil)
    private let mappingButton = NSButton(title: "Use This Set", target: nil, action: nil)
    private var previews: [WallpaperPhase: NSImageView] = [:]
    private var rolePickers: [WallpaperPhase: NSPopUpButton] = [:]
    private var draftSetID: String?
    private var draftMapping: [WallpaperPhase: String] = [:]
    private var renderedSet: WallpaperSet?
    private var previewIDs: [WallpaperPhase: String] = [:]
    private var documentView: NSView?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 670),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Rotation Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
    }
    required init?(coder: NSCoder) { nil }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY
        return stack
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action); result.bezelStyle = .rounded; return result
    }
    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title); label.font = .boldSystemFont(ofSize: 13); return label
    }
    private func buildContent() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedSettingsView(frame: NSRect(x: 0, y: 0, width: 580, height: 860))
        documentView = document
        scroll.documentView = document; content.addSubview(scroll)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20)
        ])
        stateLabel.font = .boldSystemFont(ofSize: 13)
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stateLabel.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(stateLabel)
        setPicker.target = self; setPicker.action = #selector(setChanged)
        setPicker.widthAnchor.constraint(equalToConstant: 350).isActive = true
        stack.addArrangedSubview(row([heading("Wallpaper Set"), setPicker]))
        var cards: [NSView] = []
        for phase in WallpaperPhase.allCases {
            let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 125).isActive = true
            image.heightAnchor.constraint(equalToConstant: 80).isActive = true
            image.setAccessibilityLabel("\(phase.title) preview")
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.target = self; picker.action = #selector(roleChanged(_:)); picker.identifier = NSUserInterfaceItemIdentifier(phase.rawValue)
            picker.widthAnchor.constraint(equalToConstant: 125).isActive = true
            picker.setAccessibilityLabel("\(phase.title) scene")
            let card = NSStackView(views: [heading(phase.title), image, picker]); card.orientation = .vertical; card.alignment = .centerX; card.spacing = 4
            previews[phase] = image; rolePickers[phase] = picker; cards.append(card)
        }
        stack.addArrangedSubview(row(cards))
        mappingButton.target = self; mappingButton.action = #selector(confirmMapping)
        stack.addArrangedSubview(row([mappingButton, button("Open Apple Wallpaper Settings…", #selector(openWallpaper))]))
        stack.addArrangedSubview(heading("Today’s Solar Transitions"))
        transitionsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        transitionsLabel.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(transitionsLabel)
        stack.addArrangedSubview(heading("Location"))
        locationLabel.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(locationLabel)
        stack.addArrangedSubview(row([button("Use Current Location…", #selector(currentLocation)), button("Enter Coordinates…", #selector(manualLocation))]))
        loginToggle.target = self; loginToggle.action = #selector(loginChanged)
        stack.addArrangedSubview(row([loginToggle, button("Login Item Settings…", #selector(openLoginSettings))]))
        loginLabel.font = .systemFont(ofSize: 11); loginLabel.textColor = .secondaryLabelColor
        loginLabel.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(loginLabel)
        verificationButton.target = self; verificationButton.action = #selector(verify)
        stack.addArrangedSubview(row([button("Refresh Apple Sets", #selector(refresh)), verificationButton]))
        restoreButton.target = self; restoreButton.action = #selector(restore)
        rotationButton.target = self; rotationButton.action = #selector(rotationChanged)
        stack.addArrangedSubview(row([rotationButton, restoreButton]))
        messageLabel.font = .systemFont(ofSize: 11); messageLabel.textColor = .secondaryLabelColor
        messageLabel.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(messageLabel)
        if coordinator.readOnly {
            for view in stack.arrangedSubviews { disableActions(in: view) }
        }
    }
    private func disableActions(in view: NSView) {
        if let control = view as? NSControl { control.isEnabled = false }
        for child in view.subviews { disableActions(in: child) }
    }
    func inspectSet(_ id: String) { draftSetID = id; renderedSet = nil; render() }
    func render() {
        guard window != nil else { return }
        stateLabel.stringValue = coordinator.readiness
        messageLabel.stringValue = coordinator.message
        let id = draftSetID ?? coordinator.selectedSet?.id
        let set = coordinator.sets.first { $0.id == id }
        setPicker.removeAllItems()
        for item in coordinator.sets {
            setPicker.addItem(withTitle: item.name); setPicker.lastItem?.representedObject = item.id
        }
        if let id, let index = coordinator.sets.firstIndex(where: { $0.id == id }) { setPicker.selectItem(at: index) }
        if renderedSet != set {
            renderedSet = set; draftMapping = set.map(coordinator.mapping) ?? [:]
            for phase in WallpaperPhase.allCases {
                guard let picker = rolePickers[phase] else { continue }
                picker.removeAllItems(); picker.addItem(withTitle: "Choose scene…")
                if let set {
                    for asset in set.assets {
                        picker.addItem(withTitle: asset.name + (asset.isDownloaded ? "" : " (download)"))
                        picker.lastItem?.representedObject = asset.id
                    }
                    if let assetID = draftMapping[phase], let index = set.assets.firstIndex(where: { $0.id == assetID }) { picker.selectItem(at: index + 1) }
                }
            }
        }
        loadPreviews()
        let selectedDownloaded = set.map { set in WallpaperPhase.allCases.allSatisfy { set.asset(for: $0, mapping: draftMapping)?.isDownloaded == true } } ?? false
        mappingButton.isEnabled = !coordinator.readOnly && selectedDownloaded
        mappingButton.title = set?.requiresReview == true && set.map({ coordinator.configuration.mappings[$0.id] == nil }) == true ? "Confirm Four Scenes" : "Use This Set"
        if let snapshot = coordinator.schedule {
            let today = snapshot.transitions.filter { Calendar.autoupdatingCurrent.isDateInToday($0.date) }
            transitionsLabel.stringValue = today.map { "\(coordinator.formatTime($0.date))   \($0.phase.title)" }.joined(separator: "\n")
            if today.isEmpty {
                switch snapshot.solarCondition {
                case .polarDay: transitionsLabel.stringValue = "Polar day: no solar transitions today."
                case .polarNight: transitionsLabel.stringValue = "Polar night: no solar transitions today."
                case .normal: transitionsLabel.stringValue = "No solar transitions today."
                }
            }
        } else { transitionsLabel.stringValue = "Choose a location to see today’s six transitions." }
        if let fix = coordinator.configuration.lastFix {
            let date = DateFormatter(); date.dateStyle = .short; date.timeStyle = .short
            let coordinates = String(format: "%.4f°, %.4f°", fix.coordinate.latitude, fix.coordinate.longitude)
            let current = coordinator.currentFix.map { String(format: "%.4f°, %.4f°", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "not requested this launch"
            locationLabel.stringValue = "Current: \(current)\nSaved: \(coordinates) · \(fix.source)\nObtained: \(date.string(from: fix.capturedAt))"
        } else { locationLabel.stringValue = "Current: not requested\nSaved: no location" }
        let status = coordinator.loginStatus()
        loginToggle.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginToggle.isEnabled = !coordinator.readOnly
        switch status {
        case .enabled: loginLabel.stringValue = "Enabled in macOS Login Items."
        case .requiresApproval: loginLabel.stringValue = "Approval required in macOS Login Items."
        case .notFound: loginLabel.stringValue = "macOS could not find this app’s login service."
        default: loginLabel.stringValue = "Start at Login is off. Local build grants may need renewal after rebuilding."
        }
        rotationButton.title = coordinator.configuration.rotationEnabled ? "Pause Rotation" : (coordinator.configuration.receipt == nil ? "Enable Rotation" : "Resume Rotation")
        rotationButton.isEnabled = coordinator.configuration.rotationEnabled || coordinator.canEnable
        restoreButton.isHidden = coordinator.configuration.receipt == nil
        restoreButton.isEnabled = !coordinator.readOnly && !coordinator.verificationRunning
        verificationButton.isEnabled = !coordinator.readOnly && coordinator.inspection != nil && !coordinator.verificationRunning
        verificationButton.title = coordinator.verificationRunning ? "Checking…" : "Verify on This Mac…"
    }
    private func loadPreviews() {
        for phase in WallpaperPhase.allCases {
            let asset = renderedSet?.asset(for: phase, mapping: draftMapping)
            if previewIDs[phase] == asset?.id { continue }
            previews[phase]?.image = nil; previewIDs[phase] = asset?.id
            guard let url = asset?.previewURL, url.isFileURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 280,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            previews[phase]?.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
    }
    func windowWillClose(_ notification: Notification) {
        for image in previews.values { image.image = nil }; previews.removeAll(); previewIDs.removeAll()
        coordinator.settingsClosed()
    }
    @objc private func setChanged() { if let id = setPicker.selectedItem?.representedObject as? String { inspectSet(id) } }
    @objc private func roleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let phase = WallpaperPhase(rawValue: raw) else { return }
        draftMapping[phase] = sender.selectedItem?.representedObject as? String; loadPreviews(); render()
    }
    @objc private func confirmMapping() { if let id = renderedSet?.id { coordinator.confirmMapping(setID: id, value: draftMapping) } }
    @objc private func currentLocation() { coordinator.useCurrentLocation() }
    @objc private func manualLocation() {
        guard !coordinator.readOnly else { return }
        let alert = NSAlert(); alert.messageText = "Save Location Coordinates"
        alert.informativeText = "Latitude −90…90, longitude −180…180. Solar times are calculated locally."
        let latitude = NSTextField(string: coordinator.configuration.lastFix.map { String($0.coordinate.latitude) } ?? "")
        let longitude = NSTextField(string: coordinator.configuration.lastFix.map { String($0.coordinate.longitude) } ?? "")
        latitude.placeholderString = "Latitude"; longitude.placeholderString = "Longitude"
        let stack = NSStackView(views: [latitude, longitude]); stack.orientation = .vertical; stack.frame = NSRect(x: 0, y: 0, width: 280, height: 58)
        alert.accessoryView = stack; alert.addButton(withTitle: "Save Location"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let lat = Double(latitude.stringValue), let lon = Double(longitude.stringValue), Coordinate(latitude: lat, longitude: lon).isValid else {
            let invalid = NSAlert(); invalid.messageText = "Enter valid latitude and longitude numbers."; invalid.runModal(); return
        }
        coordinator.saveManualLocation(Coordinate(latitude: lat, longitude: lon))
    }
    @objc private func loginChanged() { coordinator.setStartAtLogin(loginToggle.state == .on) }
    @objc private func openLoginSettings() { coordinator.openLoginSettings() }
    @objc private func openWallpaper() { coordinator.openWallpaperSettings() }
    @objc private func refresh() { coordinator.refreshCatalog() }
    @objc private func verify() { coordinator.verifyNative() }
    @objc private func restore() { coordinator.restorePreviousSetup() }
    @objc private func rotationChanged() { coordinator.toggleRotation() }
    func saveSnapshot(to url: URL) {
        guard coordinator.readOnly, let view = documentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url, options: .atomic) }
    }
}

private final class FlippedSettingsView: NSView {
    override var isFlipped: Bool { true }
}
