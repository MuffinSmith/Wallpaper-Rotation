import AppKit
import ImageIO
import RotationCore
import AppleWallpaper
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: AppCoordinator
    private let setPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let currentLabel = NSTextField(labelWithString: "")
    private let nextLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rotationSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: "Open Login Settings…", target: nil, action: nil)
    private let locationSummary = NSTextField(labelWithString: "")
    private let locationDetail = NSTextField(wrappingLabelWithString: "")
    private let customizeButton = NSButton(title: "Customize Scenes…", target: nil, action: nil)
    private let mappingButton = NSButton(title: "Save Scenes", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download Set", target: nil, action: nil)
    private let downloadStatus = NSTextField(wrappingLabelWithString: "")
    private let downloadIndicator = NSProgressIndicator()
    private let downloadProgressLabel = NSTextField(labelWithString: "")
    private let cancelDownloadButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let downloadFallbackButton = NSButton(title: "Open Wallpaper Settings…", target: nil, action: nil)
    private let downloadProgressRow = NSStackView()
    private let restoreButton = NSButton(title: "Restore Previous Setup…", target: nil, action: nil)
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let scheduleRows = NSStackView()
    private let scheduleDateLabel = NSTextField(labelWithString: "")
    private let customization = NSStackView()
    private let mappingHelp = NSTextField(wrappingLabelWithString: "Choose the Apple scene to use at each time of day.")
    private var previews: [WallpaperPhase: ScenePreviewView] = [:]
    private var rolePickers: [WallpaperPhase: NSPopUpButton] = [:]
    private var draftSetID: String?
    private var draftMapping: [WallpaperPhase: String] = [:]
    private var renderedSet: WallpaperSet?
    private var previewIDs: [WallpaperPhase: String] = [:]
    private var customizationExpanded = false
    private var hasDraftEdits = false
    private var documentView: NSView?
    private var scrollView: NSScrollView?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Rotation"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
    }
    required init?(coder: NSCoder) { nil }

    private func label(_ title: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       secondary: Bool = false) -> NSTextField {
        let result = NSTextField(labelWithString: title)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = secondary ? .secondaryLabelColor : .labelColor
        return result
    }
    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func vertical(_ views: [NSView], spacing: CGFloat = 5) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func button(_ title: String, _ action: Selector, quiet: Bool = false) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = quiet ? .inline : .rounded
        return result
    }
    private func section(_ heading: String, views: [NSView], trailing: NSView? = nil) -> NSStackView {
        let title = row([label(heading, size: 13, weight: .medium), spacer()] + (trailing.map { [$0] } ?? []))
        let group = SettingsGroupView()
        let contents = vertical(views, spacing: 12)
        contents.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            contents.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            contents.topAnchor.constraint(equalTo: group.topAnchor, constant: 12),
            contents.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -12)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true }
        let result = vertical([title, group], spacing: 7)
        title.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        group.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        return result
    }
    private func buildContent() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(frame: content.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scrollView = scroll
        let document = SettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 680, height: 790))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; content.addSubview(scroll); documentView = document
        let form = vertical([], spacing: 16)
        form.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])

        rotationSwitch.target = self; rotationSwitch.action = #selector(rotationChanged)
        rotationSwitch.setAccessibilityLabel("Automatic wallpaper rotation")
        let titleRow = row([label("Wallpaper", size: 22, weight: .semibold), spacer(),
                            label("Rotate Automatically"), rotationSwitch])
        currentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        currentLabel.lineBreakMode = .byTruncatingMiddle
        nextLabel.font = .systemFont(ofSize: 12); nextLabel.textColor = .secondaryLabelColor
        let header = vertical([titleRow, currentLabel, nextLabel], spacing: 5)
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        form.addArrangedSubview(header)

        setPicker.target = self; setPicker.action = #selector(setChanged)
        setPicker.widthAnchor.constraint(equalToConstant: 330).isActive = true
        setPicker.setAccessibilityLabel("Wallpaper set")
        let selection = row([label("Wallpaper Set"), spacer(), setPicker])
        let gallery = row([], spacing: 12)
        gallery.distribution = .fillEqually; gallery.alignment = .top
        for phase in WallpaperPhase.allCases {
            let preview = ScenePreviewView()
            preview.setAccessibilityLabel("\(phase.title) wallpaper preview")
            let caption = label(phase.title, size: 12, weight: .medium)
            caption.alignment = .center; caption.lineBreakMode = .byWordWrapping; caption.maximumNumberOfLines = 2
            let card = vertical([preview, caption], spacing: 7); card.alignment = .centerX
            caption.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            preview.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 0.64).isActive = true
            gallery.addArrangedSubview(card); previews[phase] = preview
        }
        downloadStatus.font = .systemFont(ofSize: 12); downloadStatus.textColor = .secondaryLabelColor
        downloadStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadButton.target = self; downloadButton.action = #selector(downloadSet)
        downloadButton.bezelStyle = .rounded
        let downloadRow = row([downloadStatus, spacer(), downloadButton])
        downloadIndicator.style = .bar; downloadIndicator.minValue = 0; downloadIndicator.maxValue = 1
        downloadIndicator.widthAnchor.constraint(equalToConstant: 160).isActive = true
        downloadProgressLabel.font = .systemFont(ofSize: 12); downloadProgressLabel.textColor = .secondaryLabelColor
        downloadProgressLabel.lineBreakMode = .byTruncatingMiddle
        downloadProgressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelDownloadButton.target = self; cancelDownloadButton.action = #selector(cancelDownload)
        cancelDownloadButton.bezelStyle = .inline
        downloadProgressRow.orientation = .horizontal; downloadProgressRow.alignment = .centerY; downloadProgressRow.spacing = 10
        for view in [downloadIndicator, downloadProgressLabel, spacer(), cancelDownloadButton] { downloadProgressRow.addArrangedSubview(view) }
        downloadFallbackButton.target = self; downloadFallbackButton.action = #selector(openWallpaper)
        downloadFallbackButton.bezelStyle = .inline; downloadFallbackButton.alignment = .left
        customizeButton.target = self; customizeButton.action = #selector(toggleCustomization)
        customizeButton.bezelStyle = .inline
        mappingButton.target = self; mappingButton.action = #selector(confirmMapping)
        mappingButton.bezelStyle = .rounded
        let sceneActions = row([customizeButton, spacer(), mappingButton])
        customization.orientation = .vertical; customization.alignment = .leading; customization.spacing = 10
        mappingHelp.font = .systemFont(ofSize: 12); mappingHelp.textColor = .secondaryLabelColor
        customization.addArrangedSubview(mappingHelp)
        mappingHelp.widthAnchor.constraint(equalTo: customization.widthAnchor).isActive = true
        for phase in WallpaperPhase.allCases {
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.target = self; picker.action = #selector(roleChanged(_:))
            picker.identifier = NSUserInterfaceItemIdentifier(phase.rawValue)
            picker.setAccessibilityLabel("Scene for \(phase.title)")
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let caption = label(phase.title)
            caption.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let mappingRow = row([caption, picker])
            customization.addArrangedSubview(mappingRow)
            mappingRow.widthAnchor.constraint(equalTo: customization.widthAnchor).isActive = true
            rolePickers[phase] = picker
        }
        form.addArrangedSubview(section("Scenes", views: [selection, gallery, downloadRow, downloadProgressRow, downloadFallbackButton, sceneActions, customization]))

        scheduleRows.orientation = .vertical; scheduleRows.alignment = .leading; scheduleRows.spacing = 0
        scheduleDateLabel.font = .systemFont(ofSize: 12); scheduleDateLabel.textColor = .secondaryLabelColor
        form.addArrangedSubview(section("Today’s Schedule", views: [scheduleRows],
                                        trailing: scheduleDateLabel))

        locationSummary.font = .systemFont(ofSize: 13)
        locationDetail.font = .systemFont(ofSize: 12); locationDetail.textColor = .secondaryLabelColor
        let locationText = vertical([locationSummary, locationDetail], spacing: 4)
        let locationRow = row([locationText, spacer(), button("Change…", #selector(changeLocation(_:)))])
        form.addArrangedSubview(section("Location", views: [locationRow]))

        loginSwitch.target = self; loginSwitch.action = #selector(loginChanged)
        loginSwitch.setAccessibilityLabel("Start at Login")
        loginLabel.font = .systemFont(ofSize: 12); loginLabel.textColor = .secondaryLabelColor
        let loginText = vertical([label("Start at Login"), loginLabel], spacing: 4)
        let loginRow = row([loginText, spacer(), loginSwitch])
        loginSettingsButton.target = self; loginSettingsButton.action = #selector(openLoginSettings)
        loginSettingsButton.bezelStyle = .inline
        loginSettingsButton.alignment = .left
        form.addArrangedSubview(section("General", views: [loginRow, loginSettingsButton]))

        moreButton.addItem(withTitle: "More…")
        for (title, action) in [("Refresh Apple Sets", #selector(refresh)),
                                ("Open Wallpaper Settings…", #selector(openWallpaper)),
                                ("Login Item Settings…", #selector(openLoginSettings))] {
            moreButton.addItem(withTitle: title); moreButton.lastItem?.target = self; moreButton.lastItem?.action = action
        }
        moreButton.bezelStyle = .inline
        restoreButton.target = self; restoreButton.action = #selector(restore); restoreButton.bezelStyle = .rounded
        form.addArrangedSubview(row([moreButton, spacer(), restoreButton]))
        stateLabel.font = .systemFont(ofSize: 12); stateLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12); messageLabel.textColor = .secondaryLabelColor
        form.addArrangedSubview(stateLabel); form.addArrangedSubview(messageLabel)
        for view in form.arrangedSubviews { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
    }

    func inspectSet(_ id: String) {
        draftSetID = id; renderedSet = nil; hasDraftEdits = false; render()
    }
    func render() {
        guard window != nil else { return }
        currentLabel.stringValue = "Now: \(coordinator.currentTitle)"
        nextLabel.stringValue = coordinator.nextTitle
        rotationSwitch.state = coordinator.configuration.rotationEnabled ? .on : .off
        rotationSwitch.isEnabled = !coordinator.readOnly && (coordinator.configuration.rotationEnabled || coordinator.canEnable)
        stateLabel.stringValue = coordinator.readiness
        stateLabel.isHidden = ["Rotation enabled", "Paused: By you", "Paused: Not enabled"].contains(coordinator.readiness)
        let routineMessages = ["Location saved.", "Apple sets refreshed.", "Start at Login updated.", "Following Mac location",
                               "Resuming uses your current wallpaper setup as the restore baseline."]
        messageLabel.stringValue = coordinator.message
        messageLabel.isHidden = coordinator.message.isEmpty || routineMessages.contains(coordinator.message)

        let id = draftSetID ?? coordinator.browsedSet?.id ?? coordinator.selectedSet?.id
        let set = coordinator.sets.first { $0.id == id }
        setPicker.removeAllItems()
        for item in coordinator.sets {
            setPicker.addItem(withTitle: item.name); setPicker.lastItem?.representedObject = item.id
        }
        if let id, let index = coordinator.sets.firstIndex(where: { $0.id == id }) { setPicker.selectItem(at: index) }
        setPicker.isEnabled = !coordinator.readOnly
        // Movie availability is a live filesystem property, so equality of
        // catalog models cannot tell us whether picker labels need refreshing.
        if renderedSet?.id != set?.id {
            draftMapping = set.map(coordinator.mapping) ?? [:]; hasDraftEdits = false
        }
        renderedSet = set
        for phase in WallpaperPhase.allCases {
            guard let picker = rolePickers[phase] else { continue }
            let assets = set?.assets ?? []
            let existing = picker.itemArray.dropFirst().compactMap { $0.representedObject as? String }
            if picker.numberOfItems == 0 || existing != assets.map(\.id) {
                picker.removeAllItems(); picker.addItem(withTitle: "Choose an Apple scene…")
                for asset in assets {
                    picker.addItem(withTitle: asset.name)
                    picker.lastItem?.representedObject = asset.id
                }
            }
            // Update status in place; rebuilding a tracked popup during byte
            // progress can move the item underneath the user's pointer.
            for (index, asset) in assets.enumerated() {
                picker.item(at: index + 1)?.title = asset.name + (asset.isDownloaded ? "" : " — Download required")
            }
            let selected = draftMapping[phase].flatMap { id in assets.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            if picker.indexOfSelectedItem != selected { picker.selectItem(at: selected) }
            picker.isEnabled = !coordinator.readOnly
        }
        let needsReview = set.map { $0.requiresReview && coordinator.configuration.mappings[$0.id] == nil } ?? false
        customization.isHidden = !customizationExpanded && !needsReview
        customizeButton.title = customization.isHidden ? "Customize Scenes…" : "Hide Scene Choices"
        let selectedDownloaded = set.map { set in WallpaperPhase.allCases.allSatisfy { set.asset(for: $0, mapping: draftMapping)?.isDownloaded == true } } ?? false
        mappingButton.isHidden = !needsReview && !hasDraftEdits && set?.id == coordinator.selectedSet?.id
        mappingButton.title = needsReview ? "Confirm Scenes" : (set?.id == coordinator.selectedSet?.id ? "Save Scenes" : "Use This Set")
        mappingButton.isEnabled = !coordinator.readOnly && selectedDownloaded
        mappingHelp.stringValue = needsReview ? "Review the four scenes before using this set. Your current wallpaper will stay in place." : "Choose the Apple scene to use at each time of day."
        renderDownloads(set: set, needsReview: needsReview, selectedDownloaded: selectedDownloaded)
        loadPreviews()
        renderSchedule()
        renderLocation()
        let status = coordinator.loginStatus()
        loginSwitch.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginSwitch.isEnabled = !coordinator.readOnly
        loginSettingsButton.isHidden = status != .requiresApproval && status != .notFound
        loginSettingsButton.isEnabled = !coordinator.readOnly
        switch status {
        case .requiresApproval: loginLabel.stringValue = "Allow Wallpaper Rotation in Login Items to finish turning this on."
        case .notFound: loginLabel.stringValue = "This app’s login item is unavailable."
        default: loginLabel.stringValue = "Open Wallpaper Rotation automatically when you log in."
        }
        moreButton.isEnabled = !coordinator.readOnly
        restoreButton.isHidden = coordinator.configuration.receipt == nil
        restoreButton.isEnabled = !coordinator.readOnly && !coordinator.verificationRunning
    }
    private func renderDownloads(set: WallpaperSet?, needsReview: Bool, selectedDownloaded: Bool) {
        let missing = set?.assets.filter { !$0.isDownloaded } ?? []
        let downloadable = missing.filter { $0.downloadURL != nil }
        let unavailable = missing.count - downloadable.count
        downloadButton.isHidden = missing.isEmpty
        downloadButton.title = downloadable.isEmpty ? "Download in Apple Settings…" : "Download Set"
        downloadButton.isEnabled = !coordinator.readOnly && !coordinator.downloadRunning
        downloadFallbackButton.isHidden = unavailable == 0 || downloadable.isEmpty
        downloadFallbackButton.isEnabled = !coordinator.readOnly
        if set == nil {
            downloadStatus.stringValue = "Choose an Apple wallpaper set."
        } else if missing.isEmpty {
            downloadStatus.stringValue = needsReview ? "Downloaded. Review the four scene choices below." : "Downloaded and ready to use."
        } else if selectedDownloaded {
            downloadStatus.stringValue = "Your chosen scenes are ready. \(missing.count) other \(missing.count == 1 ? "scene is" : "scenes are") available to download."
        } else if unavailable > 0 {
            downloadStatus.stringValue = downloadable.isEmpty
                ? "\(unavailable) \(unavailable == 1 ? "scene needs" : "scenes need") to be downloaded in Apple Wallpaper Settings."
                : "\(missing.count) scenes are missing. \(unavailable) must be downloaded in Apple Wallpaper Settings."
        } else {
            downloadStatus.stringValue = "\(missing.count) \(missing.count == 1 ? "scene is" : "scenes are") available to download."
        }
        downloadProgressRow.isHidden = !coordinator.downloadRunning
        cancelDownloadButton.isEnabled = !coordinator.readOnly
        guard coordinator.downloadRunning else { downloadIndicator.stopAnimation(nil); return }
        let name = coordinator.sets.first { $0.id == coordinator.downloadingSetID }?.name ?? "wallpaper set"
        if let progress = coordinator.downloadProgress {
            downloadProgressLabel.stringValue = "\(name) · \(progress.completedCount) of \(progress.totalCount) scenes"
            if let fraction = progress.fractionCompleted, fraction.isFinite {
                downloadIndicator.isIndeterminate = false; downloadIndicator.stopAnimation(nil)
                downloadIndicator.doubleValue = min(1, max(0, fraction))
            } else {
                downloadIndicator.isIndeterminate = true; downloadIndicator.startAnimation(nil)
            }
        } else {
            downloadProgressLabel.stringValue = "Preparing \(name)…"
            downloadIndicator.isIndeterminate = true; downloadIndicator.startAnimation(nil)
        }
    }
    private func renderSchedule() {
        let todayFormatter = DateFormatter(); todayFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        scheduleDateLabel.stringValue = todayFormatter.string(from: Date())
        for view in scheduleRows.arrangedSubviews { scheduleRows.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let snapshot = coordinator.schedule else {
            scheduleRows.addArrangedSubview(label("Choose a location to see today’s schedule.", size: 12, secondary: true)); return
        }
        let today = snapshot.transitions.filter { Calendar.autoupdatingCurrent.isDateInToday($0.date) }
        if today.isEmpty {
            let text: String
            switch snapshot.solarCondition {
            case .polarDay: text = "Polar day — no solar transitions today."
            case .polarNight: text = "Polar night — no solar transitions today."
            case .normal: text = "No solar transitions today."
            }
            scheduleRows.addArrangedSubview(label(text, size: 12, secondary: true)); return
        }
        for (index, transition) in today.enumerated() {
            let isNext = coordinator.configuration.rotationEnabled && transition == snapshot.nextTransition
            let time = label(coordinator.formatTime(transition.date), weight: isNext ? .medium : .regular)
            time.font = .monospacedDigitSystemFont(ofSize: 13, weight: isNext ? .medium : .regular)
            time.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let dot = PhaseDotView(phase: transition.phase)
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true; dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            let phase = label(transition.phase.title, weight: isNext ? .medium : .regular)
            let next = label(isNext ? "Next" : "", size: 11, secondary: true)
            let item = row([time, dot, phase, spacer(), next], spacing: 10)
            item.heightAnchor.constraint(equalToConstant: 22).isActive = true
            scheduleRows.addArrangedSubview(item); item.widthAnchor.constraint(equalTo: scheduleRows.widthAnchor).isActive = true
            if index < today.count - 1 {
                let divider = NSBox(); divider.boxType = .separator
                scheduleRows.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: scheduleRows.widthAnchor).isActive = true
            }
        }
    }
    private func coordinates(_ fix: LocationFix) -> String {
        String(format: "%.2f° %@, %.2f° %@", abs(fix.coordinate.latitude), fix.coordinate.latitude >= 0 ? "N" : "S",
               abs(fix.coordinate.longitude), fix.coordinate.longitude >= 0 ? "E" : "W")
    }
    private func renderLocation() {
        guard let fix = coordinator.configuration.lastFix else {
            locationSummary.stringValue = "Choose Your Location"
            locationDetail.stringValue = "Sunrise and sunset times are calculated on this Mac."
            return
        }
        locationSummary.stringValue = coordinates(fix)
        let date = DateFormatter(); date.dateStyle = .short; date.timeStyle = .short
        let source = fix.source == "Manual coordinates" ? "Saved coordinates" : "Saved Mac location"
        locationDetail.stringValue = "\(source) · Updated \(date.string(from: fix.capturedAt))"
    }
    private func loadPreviews() {
        let actual = Set(coordinator.inspection?.selections.values.map { $0 } ?? [])
        for phase in WallpaperPhase.allCases {
            let asset = renderedSet?.asset(for: phase, mapping: draftMapping)
            previews[phase]?.isCurrent = asset.map { actual.count == 1 && actual.contains($0.id) } ?? false
            if previewIDs[phase] == asset?.id { continue }
            previews[phase]?.image = nil; previewIDs[phase] = asset?.id
            guard let url = asset?.previewURL, url.isFileURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 420,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            previews[phase]?.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
    }
    func windowWillClose(_ notification: Notification) {
        downloadIndicator.stopAnimation(nil)
        for preview in previews.values { preview.image = nil }
        previews.removeAll(); previewIDs.removeAll(); rolePickers.removeAll()
        scrollView?.documentView = nil; documentView = nil; scrollView = nil
        coordinator.settingsClosed()
    }
    @objc private func setChanged() {
        guard let id = setPicker.selectedItem?.representedObject as? String else { return }
        inspectSet(id)
        guard !coordinator.readOnly else { return }
        coordinator.select(id)
        if coordinator.selectedSet?.id == id { draftSetID = nil }
        render()
    }
    @objc private func toggleCustomization() { customizationExpanded.toggle(); render() }
    @objc private func roleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let phase = WallpaperPhase(rawValue: raw) else { return }
        draftMapping[phase] = sender.selectedItem?.representedObject as? String
        hasDraftEdits = true; loadPreviews(); render()
    }
    @objc private func confirmMapping() {
        guard let id = renderedSet?.id else { return }
        coordinator.confirmMapping(setID: id, value: draftMapping)
        if coordinator.selectedSet?.id == id { draftSetID = nil; hasDraftEdits = false }
        render()
    }
    @objc private func changeLocation(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("Use Current Location…", #selector(currentLocation)), ("Enter Coordinates…", #selector(manualLocation))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = !coordinator.readOnly; menu.addItem(item)
        }
        menu.addItem(.separator())
        let details = NSMenuItem(title: "Location Details…", action: #selector(locationDetails), keyEquivalent: "")
        details.target = self; menu.addItem(details)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    @objc private func locationDetails() {
        let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .short
        let current = coordinator.currentFix.map { "\(coordinates($0)) · \(date.string(from: $0.capturedAt))" } ?? "Not requested this launch"
        let saved = coordinator.configuration.lastFix.map { "\(coordinates($0))\n\($0.source) · \(date.string(from: $0.capturedAt))" } ?? "No saved location"
        let alert = NSAlert(); alert.messageText = "Location Details"
        alert.informativeText = "Current Mac location\n\(current)\n\nSaved location used for the schedule\n\(saved)"
        alert.addButton(withTitle: "Done")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    @objc private func currentLocation() { coordinator.useCurrentLocation() }
    @objc private func manualLocation() {
        guard !coordinator.readOnly else { return }
        let alert = NSAlert(); alert.messageText = "Set Location"
        alert.informativeText = "Enter latitude (−90 to 90) and longitude (−180 to 180)."
        let latitude = NSTextField(string: coordinator.configuration.lastFix.map { String($0.coordinate.latitude) } ?? "")
        let longitude = NSTextField(string: coordinator.configuration.lastFix.map { String($0.coordinate.longitude) } ?? "")
        latitude.placeholderString = "Latitude"; longitude.placeholderString = "Longitude"
        let fields = NSGridView(views: [[label("Latitude"), latitude], [label("Longitude"), longitude]])
        fields.rowSpacing = 10; fields.columnSpacing = 12; fields.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        fields.column(at: 0).xPlacement = .trailing; fields.column(at: 1).width = 190
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save Location"); alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] result in
                guard result == .alertFirstButtonReturn else { return }
                self?.saveManualCoordinates(latitude: latitude.stringValue, longitude: longitude.stringValue)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            saveManualCoordinates(latitude: latitude.stringValue, longitude: longitude.stringValue)
        }
    }
    private func saveManualCoordinates(latitude: String, longitude: String) {
        guard let lat = Double(latitude), let lon = Double(longitude), Coordinate(latitude: lat, longitude: lon).isValid else {
            let invalid = NSAlert(); invalid.messageText = "Enter valid latitude and longitude numbers."
            if let window { invalid.beginSheetModal(for: window) } else { invalid.runModal() }
            return
        }
        coordinator.saveManualLocation(Coordinate(latitude: lat, longitude: lon))
    }
    @objc private func downloadSet() {
        guard !coordinator.readOnly, let id = renderedSet?.id else { return }
        if renderedSet?.assets.contains(where: { !$0.isDownloaded && $0.downloadURL != nil }) == true {
            coordinator.downloadSet(id)
        } else {
            coordinator.openWallpaperSettings()
        }
    }
    @objc private func cancelDownload() { guard !coordinator.readOnly else { return }; coordinator.cancelDownload() }
    @objc private func loginChanged() { coordinator.setStartAtLogin(loginSwitch.state == .on) }
    @objc private func openLoginSettings() { coordinator.openLoginSettings() }
    @objc private func openWallpaper() { coordinator.openWallpaperSettings() }
    @objc private func refresh() { coordinator.refreshCatalog() }
    @objc private func restore() { coordinator.restorePreviousSetup() }
    @objc private func rotationChanged() { coordinator.toggleRotation() }
    func saveSnapshot(to url: URL) {
        guard coordinator.readOnly, let view = documentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url, options: .atomic) }
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

private final class SettingsGroupView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

private final class ScenePreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSColor.quaternaryLabelColor.setFill(); frame.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(frame.width / image.size.width, frame.height / image.size.height)
            let size = NSSize(width: frame.width / scale, height: frame.height / scale)
            let source = NSRect(x: (image.size.width - size.width) / 2, y: (image.size.height - size.height) / 2,
                                width: size.width, height: size.height)
            image.draw(in: frame, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            let text = "Preview unavailable" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        if isCurrent { NSColor.controlAccentColor.setStroke(); shape.lineWidth = 2; shape.stroke() }
    }
}

private final class PhaseDotView: NSView {
    private let phase: WallpaperPhase
    init(phase: WallpaperPhase) { self.phase = phase; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch phase {
        case .day: color = .systemYellow
        case .sunset: color = .systemOrange
        case .evening: color = .systemIndigo
        case .night: color = .secondaryLabelColor
        }
        color.setFill(); NSBezierPath(ovalIn: bounds).fill()
    }
}
