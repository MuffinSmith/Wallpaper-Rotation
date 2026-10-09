import AppKit
import ServiceManagement
import RotationCore
import AppleWallpaper
import Darwin

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let readOnly = CommandLine.arguments.contains("--read-only-smoke")
    private(set) var configuration = AppConfiguration()
    private(set) var sets: [WallpaperSet] = []
    private(set) var schedule: ScheduleSnapshot?
    private(set) var message = ""
    private(set) var inspection: StoreInspection?
    private(set) var currentFix: LocationFix?
    private(set) var configurationLoadError: String?
    private var statusItem: NSStatusItem!
    private var menuTracking = false
    private var terminationPending = false
    private var settings: SettingsWindowController?
    private var timer: Timer?
    private var watch: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var changeDebounce: Timer?
    private var lastAutomaticLocationRequest = Date.distantPast
    private let adapter: NativeWallpaperAdapter
    private let solar = SolarSchedule()
    private lazy var location: LocationService = {
        let service = LocationService()
        service.onFix = { [weak self] fix in self?.receive(fix) }
        service.onStatus = { [weak self] text in self?.message = text; self?.render() }
        return service
    }()
    private var verificationProcess: Process?
    private var visualReceipt: OwnershipReceipt?
    private var visualAssetID: String?
    private var visualPanel: NSPanel?
    private var recoveryUncertain = false
    private var pendingApply: PendingVisualVerification?
    private var downloadTask: Task<Void, Never>?
    private var downloader: (any WallpaperDownloading)?
    private var availabilityObserver: AssetAvailabilityObserver?
    private(set) var downloadingSetID: String?
    private(set) var downloadProgress: WallpaperDownloadProgress?
    private var browsedSetID: String?
    private let nativeWorker: NativeApplyWorker
    private var nativeTask: Task<Void, Never>?
    private var queuedNativeApply = false
    private var catalogRefreshPending = false
    private var nativeTransactionID: UUID?
    var nativeOperationRunning: Bool { nativeTask != nil }
    struct EnableEnvironment {
        let isReady: () -> Bool
        let saveConfiguration: (AppConfiguration) throws -> Void
        let applyAsset: ((String) -> Void)?
        let checkCompatibility: (@escaping () -> Void) -> Void
        let showSettings: () -> Void
        var replyToTermination: ((Bool) -> Void)? = nil
        var makeDownloader: (() -> any WallpaperDownloading)? = nil
    }
    private let enableEnvironment: EnableEnvironment?

    override convenience init() {
        self.init(configuration: AppConfiguration(), sets: [], enableEnvironment: nil, nativeWorker: NativeApplyWorker())
    }
    init(configuration: AppConfiguration, sets: [WallpaperSet], enableEnvironment: EnableEnvironment?,
         nativeWorker: NativeApplyWorker = NativeApplyWorker(),
         nativeAdapter: NativeWallpaperAdapter = NativeWallpaperAdapter()) {
        self.configuration = configuration
        self.sets = sets
        self.enableEnvironment = enableEnvironment
        self.nativeWorker = nativeWorker
        self.adapter = nativeAdapter
        super.init()
    }
    var downloadRunning: Bool { downloadTask != nil }
    var browsedSet: WallpaperSet? { sets.first { $0.id == browsedSetID } ?? selectedSet }
    var verificationRunning: Bool { verificationProcess != nil || visualAssetID != nil }

    var selectedSet: WallpaperSet? {
        if let id = configuration.selectedSetID { return sets.first { $0.id == id } }
        return sets.first { set in set.assets.contains { $0.shotID == "GG_A_DAY" } && set.assets.contains { $0.shotID == "GG_A_NIGHT" } }
            ?? sets.first { $0.name == "Golden Gate" }
            ?? sets.first { ready($0) }
    }
    var nativeReady: Bool { enableEnvironment?.isReady() ?? (inspection.map { AppStorage.smokePassed(for: $0) } ?? false) }
    private var canPrepareRotation: Bool {
        !readOnly && !terminationPending && !nativeOperationRunning && configurationLoadError == nil && pendingApply == nil && (enableEnvironment != nil || watchFD >= 0) && !verificationRunning && (enableEnvironment != nil || inspection != nil) && configuration.lastFix != nil
    }
    // Runtime application is governed by the committed selection, even while another set is browsed.
    var canEnable: Bool { canPrepareRotation && ready(selectedSet) }
    private var requestedRotationSelection: RotationSelection? {
        if let settings { return settings.rotationSelection }
        let id = browsedSetID ?? selectedSet?.id
        guard let set = sets.first(where: { $0.id == id }) else { return nil }
        return RotationSelection(setID: set.id, mapping: mapping(for: set))
    }
    var canEnableRequestedRotation: Bool {
        canEnableRotation(using: requestedRotationSelection)
    }
    func canEnableRotation(using selection: RotationSelection?) -> Bool {
        canPrepareRotation && selection.map { $0.problem(in: sets) == nil } == true
    }
    var readiness: String {
        if readOnly { return "Read-only preview: no settings or wallpaper changes." }
        if nativeOperationRunning { return configuration.rotationEnabled ? "Updating wallpaper…" : "Finishing wallpaper update; rotation is paused." }
        if pendingApply != nil { return "An interrupted wallpaper update needs recovery; rotation is disabled." }
        if verificationProcess != nil { return "Native check running; rotation is paused." }
        if visualAssetID != nil { return recoveryUncertain ? "A previous visual check needs recovery; rotation is disabled." : "Inspect the temporary Day scene, then confirm or cancel and restore it." }
        if let error = configurationLoadError { return error }
        if inspection == nil { return "Native wallpaper storage is unavailable. \(message)" }
        if watchFD < 0 { return "Wallpaper change monitoring is unavailable; rotation is paused." }
        if configuration.lastFix == nil { return "Choose a location to calculate today’s transitions." }
        if !configuration.rotationEnabled {
            if let selection = requestedRotationSelection, let problem = selection.problem(in: sets) { return problem }
            if requestedRotationSelection == nil { return "Choose a wallpaper set before enabling rotation." }
        } else if !ready(selectedSet) { return "Review all four scenes and download their Apple assets before enabling." }
        if !nativeReady { return "Compatibility will be checked when you enable rotation." }
        return configuration.rotationEnabled ? "Rotation enabled" : "Paused: \(configuration.pauseReason ?? "By you")"
    }
    var currentTitle: String {
        guard let selections = inspection?.selections, !selections.isEmpty else { return "Current wallpaper: Apple settings" }
        let values = Set(selections.values)
        guard values.count == 1 else { return "Current wallpaper: multiple scenes" }
        guard let id = values.first,
              let set = sets.first(where: { $0.assets.contains(where: { $0.id == id }) }) else {
            return "Current wallpaper: Apple settings"
        }
        let phase = WallpaperPhase.allCases.first { set.asset(for: $0, mapping: mapping(for: set))?.id == id }
        return "\(set.name) · \(phase?.title ?? "Current scene")"
    }
    var nextTitle: String {
        guard configuration.rotationEnabled else { return "Rotation paused" }
        guard let next = schedule?.nextTransition else { return "No transition scheduled" }
        let calendar = Calendar.autoupdatingCurrent
        let when: String
        if calendar.isDateInToday(next.date) { when = formatTime(next.date) }
        else if calendar.isDateInTomorrow(next.date) { when = "Tomorrow, \(formatTime(next.date))" }
        else {
            let date = DateFormatter(); date.dateStyle = .medium; date.timeStyle = .short
            when = date.string(from: next.date)
        }
        return "Next: \(next.phase.title) · \(when)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !readOnly, let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.muffinsmith.WallpaperRotation")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        do { configuration = try AppStorage.load() } catch {
            configurationLoadError = error.localizedDescription
            message = error.localizedDescription
        }
        if readOnly { configuration.rotationEnabled = false }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallpaper Rotation")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; statusItem.menu = menu
        refreshCatalog()
        if !readOnly {
            recoverPendingApply()
            startNativeObservation()
            let catalog = AppleSetCatalog()
            availabilityObserver = AssetAvailabilityObserver(
                directories: [catalog.videosDirectory, catalog.manifestURL.deletingLastPathComponent()]) { [weak self] in
                    self?.refreshAvailability()
                }
            availabilityObserver?.start()
            NotificationCenter.default.addObserver(self, selector: #selector(availabilityMayHaveChanged),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            recoverPendingVisualVerification()
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(self, selector: #selector(lifecycleChanged), name: NSWorkspace.didWakeNotification, object: nil)
            workspace.addObserver(self, selector: #selector(lifecycleChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged), name: .NSSystemTimeZoneDidChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged), name: .NSCalendarDayChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged), name: .NSSystemClockDidChange, object: nil)
            if configuration.rotationEnabled {
                if !canEnable || !nativeReady { pause("Compatibility or setup requires review") }
                else if checkOwnership() { recalculate(apply: true) }
            }
            requestAutomaticLocationIfNeeded(force: true)
        }
        // Read-only QA can inspect a collection without changing the saved set.
        if readOnly, let index = CommandLine.arguments.firstIndex(of: "--preview-set"),
           CommandLine.arguments.indices.contains(index + 1),
           sets.contains(where: { $0.id == CommandLine.arguments[index + 1] }) {
            browsedSetID = CommandLine.arguments[index + 1]
        }
        render()
        if readOnly && CommandLine.arguments.contains("--show-menu") {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.statusItem.button?.performClick(nil) }
            }
        }
        if !CommandLine.arguments.contains("--hide-settings") && (readOnly || configuration.receipt == nil || visualAssetID != nil || pendingApply != nil) { showSettings() }
        if readOnly && (CommandLine.arguments.contains("--show-set-choices") || CommandLine.arguments.contains("--show-scene-choices")) {
            let showSets = CommandLine.arguments.contains("--show-set-choices")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.settings?.showPreviewMenuForQA(showSets: showSets) }
            }
        }
        if readOnly && CommandLine.arguments.contains("--close-settings-after-preview") {
            Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(closeReadOnlySettings), userInfo: nil, repeats: false)
        }
        if readOnly, let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.settings?.saveSnapshot(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    @objc private func closeReadOnlySettings() { guard readOnly else { return }; settings?.close() }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); stopNativeObservation()
        availabilityObserver?.stop()
        downloadTask?.cancel(); downloader?.cancel()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let operation = nativeTask {
            if !terminationPending {
                terminationPending = true
                timer?.invalidate(); timer = nil
                queuedNativeApply = false
                let pendingDownload = downloadTask
                cancelDownload()
                Task { @MainActor in
                    await operation.value
                    await pendingDownload?.value
                    self.replyToTermination(true)
                }
            }
            return .terminateLater
        }
        if verificationProcess != nil { message = "Wait for the native check to restore your setup before quitting."; render(); return .terminateCancel }
        if visualAssetID != nil && !finishVisualVerification(record: false) { return .terminateCancel }
        if let pendingDownload = downloadTask {
            if !terminationPending {
                terminationPending = true
                cancelDownload()
                Task { @MainActor in
                    await pendingDownload.value
                    // Give the download's cleanup defers time to remove its staging file.
                    self.replyToTermination(true)
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }
    private func replyToTermination(_ allowed: Bool) {
        if let reply = enableEnvironment?.replyToTermination { reply(allowed) }
        else { NSApp.reply(toApplicationShouldTerminate: allowed) }
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = false
        refreshAvailability()
        menuTracking = true
    }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; renderMenu() }

    func mapping(for set: WallpaperSet) -> [WallpaperPhase: String] { configuration.mappings[set.id] ?? set.suggestedMapping }
    func ready(_ set: WallpaperSet?) -> Bool {
        guard let set else { return false }
        if set.requiresReview && configuration.mappings[set.id] == nil { return false }
        return WallpaperPhase.allCases.allSatisfy { set.asset(for: $0, mapping: mapping(for: set))?.isDownloaded == true }
    }
    func refreshCatalog() {
        // The worker owns native readback while a transaction is in progress.
        guard !nativeOperationRunning else { catalogRefreshPending = true; render(); return }
        if enableEnvironment != nil { recalculate(apply: false); return }
        do {
            sets = try AppleSetCatalog().discover()
            inspection = try adapter.inspect()
            if message == "" { message = sets.isEmpty ? "No Apple aerial sets found." : "Apple sets refreshed." }
        } catch {
            message = error.localizedDescription; inspection = nil
            if configuration.rotationEnabled { pause("Native wallpaper storage unavailable") }
        }
        recalculate(apply: false)
    }
    func refreshAvailability() { refreshCatalog() }
    @objc private func availabilityMayHaveChanged() { refreshAvailability() }
    func select(_ id: String) {
        guard let candidate = sets.first(where: { $0.id == id }) else { return }
        browsedSetID = id
        guard ready(candidate) else {
            showSettings(); settings?.inspectSet(id)
            return
        }
        guard !readOnly else { settings?.inspectSet(id); return }
        configuration.selectedSetID = id
        if persist() { recalculate(apply: configuration.rotationEnabled) }
    }
    func downloadSet(_ id: String) {
        guard !readOnly, !terminationPending, !downloadRunning, let set = sets.first(where: { $0.id == id }) else { return }
        browsedSetID = id
        let missing = set.assets.filter { !$0.isDownloaded }
        guard !missing.isEmpty else { message = "All scenes are downloaded."; refreshAvailability(); return }
        let available = missing.filter { $0.downloadURL != nil }
        guard !available.isEmpty else { openWallpaperSettings(); return }
        let service: any WallpaperDownloading = enableEnvironment?.makeDownloader?() ?? WallpaperDownloader()
        downloader = service
        downloadingSetID = id
        downloadProgress = WallpaperDownloadProgress(completedCount: 0, totalCount: available.count)
        message = ""
        downloadTask = Task { [weak self] in
            do {
                try await service.download(assets: available) { [weak self] progress in
                    self?.downloadProgress = progress; self?.render()
                }
                guard let self else { return }
                self.message = set.assets.allSatisfy(\.isDownloaded)
                    ? "Downloads complete. Review the scenes, then use this set."
                    : "Available downloads finished. Remaining scenes need Apple Wallpaper settings."
            } catch is CancellationError {
                self?.message = "Download cancelled. Completed scenes are kept."
            } catch {
                self?.message = "Download could not finish: \(error.localizedDescription)"
            }
            guard let self else { return }
            self.downloadTask = nil; self.downloader = nil
            self.downloadingSetID = nil; self.downloadProgress = nil
            self.refreshAvailability()
        }
        render()
    }
    func cancelDownload() {
        guard !readOnly, downloadRunning else { return }
        downloadTask?.cancel(); downloader?.cancel()
        message = "Cancelling download…"; render()
    }
    func confirmMapping(setID: String, value: [WallpaperPhase: String]) {
        guard commitRotationSelection(RotationSelection(setID: setID, mapping: value)) else { return }
        browsedSetID = setID
        recalculate(apply: configuration.rotationEnabled)
    }
    private func commitRotationSelection(_ selection: RotationSelection) -> Bool {
        guard !readOnly, configurationLoadError == nil else { return false }
        do {
            configuration = try selection.commit(to: configuration, sets: sets, save: saveConfiguration)
            return true
        } catch {
            message = error.localizedDescription
            render()
            return false
        }
    }
    func receive(_ fix: LocationFix) {
        guard !readOnly, fix.coordinate.isValid else { return }
        if fix.source != "Manual coordinates" { currentFix = fix }
        configuration.lastFix = fix
        message = "Location saved."
        if persist() { recalculate(apply: configuration.rotationEnabled) }
    }
    @objc func useCurrentLocation() { guard !readOnly else { return }; location.requestLocation(userInitiated: true) }
    func saveManualLocation(_ coordinate: Coordinate) {
        receive(LocationFix(coordinate: coordinate, capturedAt: Date(), source: "Manual coordinates"))
    }
    private func requestAutomaticLocationIfNeeded(force: Bool = false) {
        let age = Date().timeIntervalSince(lastAutomaticLocationRequest)
        guard !readOnly, configuration.lastFix?.source != "Manual coordinates",
              configuration.lastFix != nil,
              age >= 900 || age < 0,
              force || configuration.lastFix.map({ Date().timeIntervalSince($0.capturedAt) > 21_600 }) == true else { return }
        lastAutomaticLocationRequest = Date()
        location.requestLocation(userInitiated: false)
    }
    @objc func toggleRotation() { requestRotationToggle(using: requestedRotationSelection) }
    func requestRotationToggle(using selection: RotationSelection?) {
        if configuration.rotationEnabled { pause("By you"); return }
        guard let selection else {
            message = "Choose a wallpaper set and all four scenes before enabling rotation."
            showSettings(); return
        }
        enableRotation(using: selection)
    }
    private func enableRotation(using selection: RotationSelection) {
        guard canPrepareRotation else { showSettings(); return }
        if let problem = selection.problem(in: sets) {
            message = problem; showSettings(); return
        }
        // Enable explicitly accepts the visible mapping, including a suggested Morning scene.
        // Persist both the chosen set and mapping before compatibility can touch native wallpaper.
        guard commitRotationSelection(selection) else { return }
        guard nativeReady else { checkCompatibilityAndEnable(selection: selection); return }
        if let receipt = configuration.receipt {
            do {
                if try adapter.hasExternalChange(since: receipt) {
                    configuration.receipt = nil
                    message = "Resuming uses your current wallpaper setup as the restore baseline."
                }
            } catch { message = error.localizedDescription; render(); return }
        }
        configuration.rotationEnabled = true; configuration.pauseReason = nil
        if persist() { recalculate(apply: true) }
    }
    private func pause(_ reason: String) {
        configuration.rotationEnabled = false; configuration.pauseReason = reason
        timer?.invalidate(); timer = nil
        _ = persist(); render()
    }
    private func recalculate(apply: Bool) {
        timer?.invalidate(); timer = nil
        if let fix = configuration.lastFix {
            do { schedule = try solar.evaluate(now: Date(), at: fix.coordinate) }
            catch { schedule = nil; message = error.localizedDescription; if configuration.rotationEnabled { pause("Solar schedule unavailable") } }
        } else { schedule = nil }
        if apply && configuration.rotationEnabled { applyCurrentScene() }
        if configuration.rotationEnabled, !terminationPending, let next = schedule?.nextTransition {
            timer = Timer.scheduledTimer(timeInterval: max(1, next.date.timeIntervalSinceNow), target: self,
                                        selector: #selector(transitionReached), userInfo: nil, repeats: false)
        }
        render()
    }
    @objc private func transitionReached() {
        requestAutomaticLocationIfNeeded()
        guard checkOwnership() else { return }
        recalculate(apply: true)
    }
    private func applyCurrentScene() {
        guard !terminationPending else { return }
        if nativeOperationRunning { queuedNativeApply = true; return }
        guard !readOnly, canEnable, nativeReady, let set = selectedSet, let phase = schedule?.phase,
              let asset = set.asset(for: phase, mapping: mapping(for: set)), asset.isDownloaded else {
            if configuration.rotationEnabled { pause("Scene or compatibility check unavailable") }; return
        }
        if let apply = enableEnvironment?.applyAsset { apply(asset.id); return }
        let previous = configuration.receipt
        queuedNativeApply = false
        let transactionID = UUID()
        nativeTransactionID = transactionID
        nativeTask = Task { [weak self, nativeWorker] in
            let result = await nativeWorker.apply(assetID: asset.id, previous: previous, transactionID: transactionID)
            guard let self else { _ = await nativeWorker.complete(result, persisted: false); return }
            guard self.nativeTransactionID == transactionID else {
                _ = await nativeWorker.complete(result, persisted: false); return
            }
            // Only merge ownership. Preserve newer set choices and the user's Pause action.
            if let receipt = result.receipt { self.configuration.receipt = receipt }
            if let inspection = result.inspection { self.inspection = inspection }
            self.pendingApply = result.pending
            if let error = result.error {
                self.message = error
                self.configuration.rotationEnabled = false
                self.configuration.pauseReason = "Native wallpaper update failed"
                self.timer?.invalidate(); self.timer = nil
            }
            let persisted = self.persist()
            let completion = await nativeWorker.complete(result, persisted: persisted)
            self.pendingApply = completion.pending
            if let error = completion.error { self.message += " Recovery needs attention: \(error)" }
            if completion.pending != nil || completion.error != nil {
                self.configuration.rotationEnabled = false
                self.timer?.invalidate(); self.timer = nil
                if persisted {
                    self.configuration.pauseReason = "Native recovery needs review"
                    _ = self.persist()
                }
            }
            self.nativeTask = nil
            self.nativeTransactionID = nil
            if self.catalogRefreshPending {
                self.catalogRefreshPending = false
                if !self.terminationPending { self.refreshAvailability() }
            }
            if self.configuration.rotationEnabled && self.queuedNativeApply && !self.terminationPending {
                self.recalculate(apply: true)
            } else { self.render() }
            if self.enableEnvironment == nil { self.scheduleNativeCheck() }
        }
        render()
    }

    private func recoverPendingApply() {
        do {
            let candidates = [AppStorage.pendingApplyURL, AppStorage.pendingSmokeURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard let pendingURL = candidates.first else { pendingApply = nil; return }
            guard candidates.count == 1 else {
                configurationLoadError = "Multiple interrupted operations need recovery. Rotation stays paused; recovery records are retained."
                configuration.rotationEnabled = false
                return
            }
            guard let pending = try AppStorage.loadPendingApply(at: pendingURL) else { return }
            pendingApply = pending
            configuration.rotationEnabled = false
            let lease: NativeOperationLease
            do { lease = try NativeOperationLease(directory: AppStorage.directory) }
            catch AppleWallpaperError.transactionBusy {
                message = "A compatibility check is still finishing. Rotation stays paused."
                _ = persist(); return
            }
            defer { lease.release() }
            // The helper may have advanced or removed its stage before we acquired the lease.
            guard let pending = try AppStorage.loadPendingApply(at: pendingURL) else { pendingApply = nil; return }
            pendingApply = pending
            timer?.invalidate(); timer = nil
            configuration.pauseReason = "Interrupted wallpaper update needs review"
            var recovered = pending.receipt ?? freshRecovery(assetID: pending.assetID, startedAt: pending.startedAt)
            var recoveredPrevious = false
            if recovered == nil, let previous = pending.previousReceipt,
               previous.osBuild == AppStorage.osBuild, try !adapter.hasExternalChange(since: previous) {
                recovered = previous; recoveredPrevious = true
            }
            guard let recovered, (recoveredPrevious || recovered.assetID == pending.assetID), recovered.osBuild == AppStorage.osBuild else {
                message = "An interrupted native update has uncertain recovery provenance. Its pending record and native backups are retained; review recovery before resuming."
                _ = persist(); return
            }
            configuration.receipt = recovered
            if persist() {
                try AppStorage.removePendingApply(at: pendingURL); pendingApply = nil
                message = "Interrupted wallpaper ownership recovered. Rotation stays paused; Restore Previous Setup is available."
            }
        } catch {
            configuration.rotationEnabled = false
            configurationLoadError = "Pending wallpaper update recovery needs attention: \(error.localizedDescription)"
            message = configurationLoadError ?? "Recovery needs attention."
        }
    }
    private func checkOwnership() -> Bool {
        guard !nativeOperationRunning else { queuedNativeApply = true; return false }
        guard !readOnly, let receipt = configuration.receipt else { return true }
        do {
            inspection = try adapter.inspect()
            if try adapter.hasExternalChange(since: receipt) { pause("Wallpaper changed outside Wallpaper Rotation"); return false }
        } catch { inspection = nil; message = error.localizedDescription; pause("Native wallpaper state could not be checked"); return false }
        return true
    }
    @objc private func lifecycleChanged() {
        guard !readOnly else { return }
        // Lifecycle reconciliation lets the adapter distinguish new contexts from changed owned ones.
        if configuration.rotationEnabled && checkOwnership() { recalculate(apply: true) }
        else { recalculate(apply: false) }
        requestAutomaticLocationIfNeeded(force: true)
    }
    /// Observe the adapter's real store directory; fixtures use this same event/debounce path.
    func startNativeObservation() {
        guard !readOnly, watch == nil else { return }
        watchFD = open(adapter.storeURL.deletingLastPathComponent().path, O_EVTONLY)
        guard watchFD >= 0 else { message = "Wallpaper change monitoring unavailable; rotation cannot safely run."; return }
        let descriptor = watchFD
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleNativeCheck()
            }
        }
        source.setCancelHandler { close(descriptor) }; watch = source; source.resume()
    }
    func stopNativeObservation() {
        changeDebounce?.invalidate(); changeDebounce = nil
        watch?.cancel(); watch = nil; watchFD = -1
    }
    private func scheduleNativeCheck() {
        changeDebounce?.invalidate()
        changeDebounce = Timer.scheduledTimer(timeInterval: 0.8, target: self, selector: #selector(nativeStoreChanged), userInfo: nil, repeats: false)
    }
    @objc private func nativeStoreChanged() {
        guard !nativeOperationRunning else { catalogRefreshPending = true; return }
        // Failed in-session operations stay paused for review. Startup and compatibility
        // completion reconcile their own journals explicitly, outside notification storms.
        if pendingApply != nil { render(); return }
        guard configuration.rotationEnabled else { inspection = try? adapter.inspect(); render(); return }
        _ = checkOwnership(); render()
    }
    private func saveConfiguration(_ value: AppConfiguration) throws {
        if let enableEnvironment { try enableEnvironment.saveConfiguration(value) }
        else { try AppStorage.save(value) }
    }
    @discardableResult private func persist() -> Bool {
        guard !readOnly, configurationLoadError == nil else { return false }
        do { try saveConfiguration(configuration); return true }
        catch { message = error.localizedDescription; configuration.rotationEnabled = false; configuration.pauseReason = "Configuration could not be saved"; render(); return false }
    }
    func loginStatus() -> SMAppService.Status { SMAppService.mainApp.status }
    func setStartAtLogin(_ enabled: Bool) {
        guard !readOnly else { return }
        if enabled {
            let path = Bundle.main.bundleURL.standardizedFileURL.path
            let personal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
            guard path.hasPrefix("/Applications/") || path.hasPrefix(personal) else {
                message = "Move Wallpaper Rotation to Applications and reopen it before enabling Start at Login."; render(); return
            }
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = loginStatus() == .requiresApproval ? "Approve Wallpaper Rotation in System Settings → Login Items." : "Start at Login updated."
        } catch { message = "Start at Login failed: \(error.localizedDescription). Local ad-hoc signing may be rejected; rebuild with SIGNING_IDENTITY if needed." }
        render()
    }
    func openLoginSettings() { guard !readOnly else { return }; SMAppService.openSystemSettingsLoginItems() }
    @objc func openWallpaperSettings() {
        guard !readOnly, let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
    func restorePreviousSetup() {
        guard !readOnly, !nativeOperationRunning, let receipt = configuration.receipt else { return }
        let alert = NSAlert(); alert.messageText = "Restore Previous Setup?"
        alert.informativeText = "Restore only wallpaper and screen saver values still owned by this app. Changes you made elsewhere will be preserved. Rotation will pause."
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        beginRestore(receipt)
    }
    func beginRestore(_ receipt: OwnershipReceipt) {
        guard !readOnly, !nativeOperationRunning else { return }
        pause("Previous setup restored")
        let transactionID = UUID()
        nativeTransactionID = transactionID
        nativeTask = Task { [weak self, nativeWorker] in
            do {
                let result = try await nativeWorker.restore(receipt, transactionID: transactionID)
                let readback = try? await nativeWorker.inspect()
                if let self, self.nativeTransactionID == transactionID {
                    if result.skippedCount == 0 { self.configuration.receipt = nil }
                    if let readback { self.inspection = readback }
                    self.message = "Restored \(result.restoredCount) values; preserved \(result.skippedCount) changed values."
                    _ = self.persist()
                }
            } catch { self?.message = error.localizedDescription }
            await nativeWorker.completeRestore(transactionID: transactionID)
            if self?.nativeTransactionID == transactionID {
                self?.nativeTask = nil
                self?.nativeTransactionID = nil
                if let self, self.catalogRefreshPending {
                    self.catalogRefreshPending = false
                    if !self.terminationPending { self.refreshAvailability() }
                }
                self?.render()
            }
        }
        render()
    }

    /// Explicit Enable authorizes this one-time round trip. OS changes never
    /// start it in the background; startup pauses until the user enables again.
    private func checkCompatibilityAndEnable(selection: RotationSelection) {
        if let enableEnvironment {
            enableEnvironment.checkCompatibility { [weak self] in self?.enableRotation(using: selection) }
            return
        }
        guard canEnable, let inspection, let set = selectedSet,
              let day = set.asset(for: .day, mapping: mapping(for: set)), day.isDownloaded,
              let night = set.asset(for: .night, mapping: mapping(for: set)), night.isDownloaded else { return }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WallpaperDiagnostics")
        process.arguments = ["--native-smoke", "--allow-live-changes", "--assets", day.id, night.id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let succeeded = process.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                self.verificationProcess = nil
                self.inspection = try? self.adapter.inspect()
                if succeeded, AppStorage.smokePassed(for: inspection), self.nativeReady {
                    self.message = ""
                    // Resume the accepted action, not a different set browsed during the check.
                    self.enableRotation(using: selection)
                } else {
                    self.recoverPendingApply()
                    if self.pendingApply == nil && self.configurationLoadError == nil {
                        self.message = "Wallpaper compatibility could not be confirmed. Rotation stays paused."
                    }
                    self.render()
                }
            }
        }
        do {
            verificationProcess = process
            try process.run()
            message = "Checking compatibility; the Day and Night scenes will briefly appear, then your setup will be restored."
            render()
        } catch {
            verificationProcess = nil
            message = "Could not check wallpaper compatibility: \(error.localizedDescription)"
            render()
        }
    }
    private func recoverPendingVisualVerification() {
        do {
            guard let pending = try AppStorage.loadPendingVerification() else { return }
            visualAssetID = pending.assetID
            visualReceipt = pending.receipt
            if visualReceipt == nil { visualReceipt = freshRecovery(assetID: pending.assetID, startedAt: pending.startedAt) }
            recoveryUncertain = visualReceipt == nil
            configuration.rotationEnabled = false
            timer?.invalidate(); timer = nil
            configuration.pauseReason = "A previous visual check needs restoration"
            message = "A previous temporary test may still be applied. Restore it before enabling rotation."
            showVisualPanel()
        } catch { configurationLoadError = "Could not read the pending verification recovery file: \(error.localizedDescription)" }
    }
    private func freshRecovery(assetID: String, startedAt: Date) -> OwnershipReceipt? {
        let url = adapter.backupDir.appendingPathComponent("ownership-recovery.json")
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let receipt = try? adapter.recoveryReceipt(),
              RecoveryJournalPolicy.canAdopt(expectedAssetID: assetID, expectedOSBuild: AppStorage.osBuild,
                startedAt: startedAt, journalAssetID: receipt.assetID, journalOSBuild: receipt.osBuild,
                journalModifiedAt: values.contentModificationDate) else { return nil }
        return receipt
    }
    private func showVisualPanel() {
        guard visualPanel == nil else { visualPanel?.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Check Wallpaper and Screen Saver"
        panel.collectionBehavior = [.canJoinAllSpaces]; panel.isReleasedWhenClosed = false
        let text = recoveryUncertain
            ? "A previous temporary check needs recovery, but its receipt could not be verified. Rotation stays disabled. Recovery data is retained in \(adapter.backupDir.path). Review the recovery guide before restoring or enabling rotation."
            : "A temporary Day scene is applied. Check the wallpaper on every monitor and desktop Space, then preview the matching animated screen saver. Have these changes worked correctly? Your previous setup will be restored when you finish."
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 20, y: 95, width: 460, height: 105)
        let preview = NSButton(title: "Preview Screen Saver", target: self, action: #selector(previewScreenSaver))
        preview.frame = NSRect(x: 20, y: 55, width: 210, height: 30)
        let confirm = NSButton(title: "Looks Correct & Restore", target: self, action: #selector(confirmVisual))
        confirm.frame = NSRect(x: 20, y: 15, width: 230, height: 30); confirm.isEnabled = visualReceipt != nil
        let cancel = NSButton(title: "Restore & Cancel", target: self, action: #selector(cancelVisual))
        cancel.frame = NSRect(x: 260, y: 15, width: 220, height: 30)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(preview)
        panel.contentView?.addSubview(confirm); panel.contentView?.addSubview(cancel)
        visualPanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    @objc private func previewScreenSaver() {
        guard !readOnly, visualReceipt != nil else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }
    @objc private func confirmVisual() { _ = finishVisualVerification(record: true) }
    @objc private func cancelVisual() { _ = finishVisualVerification(record: false) }
    @discardableResult private func finishVisualVerification(record: Bool) -> Bool {
        guard !readOnly else { return false }
        guard !recoveryUncertain else { message = "Recovery provenance is uncertain. The pending journal and backups are retained; review recovery before quitting."; render(); return false }
        do {
            let lease = try NativeOperationLease(directory: AppStorage.directory)
            defer { lease.release() }
            var skipped = 0
            if let receipt = visualReceipt { skipped = try adapter.restore(receipt).skippedCount }
            else if record { message = "A recovery receipt is required before confirming this check."; render(); return false }
            inspection = try adapter.inspect()
            if record, skipped == 0, let inspection, AppStorage.smokePassed(for: inspection) {
                try AppStorage.recordVerification(for: inspection)
                message = "Native behavior visually verified and the temporary scene restored. Login/restart verification remains pending."
            } else {
                message = skipped > 0 ? "Temporary scene restored where still owned; outside changes preserved. Visual verification was not recorded." : "Temporary scene restored; visual verification was not recorded."
            }
            try AppStorage.removePendingVerification()
            visualAssetID = nil; visualReceipt = nil; visualPanel?.close(); visualPanel = nil
            render(); return true
        } catch { message = "Temporary scene restoration failed: \(error.localizedDescription). Recovery is retained; retry Restore & Cancel before quitting."; render(); return false }
    }
    @objc func showSettings() {
        if let enableEnvironment { enableEnvironment.showSettings(); return }
        refreshAvailability()
        if settings == nil { settings = SettingsWindowController(coordinator: self) }
        settings?.showWindow(nil); NSApp.activate(); settings?.window?.makeKeyAndOrderFront(nil)
        settings?.render()
    }
    func settingsClosed() { settings = nil }
    private func render() { if statusItem != nil { renderMenu() }; settings?.render() }
    private var menuScheduleTitle: String {
        if !configuration.rotationEnabled, let reason = configuration.pauseReason { return "Paused: \(reason)" }
        return nextTitle
    }
    private func renderMenu() {
        guard let menu = statusItem?.menu else { return }
        if menuTracking {
            // Keep the tracked menu stable while byte progress and file events arrive.
            // Rebuilding it can move the item underneath the user's pointer.
            menu.items.first?.title = currentTitle
            if menu.items.count > 1 { menu.items[1].title = menuScheduleTitle }
            if let item = menu.items.first(where: { $0.identifier?.rawValue == "download-status" }) {
                let name = sets.first { $0.id == downloadingSetID }?.name ?? "Set"
                let progress = downloadProgress.map { " (\($0.completedCount)/\($0.totalCount))" } ?? ""
                item.title = downloadRunning ? "Downloading \(name)\(progress)…" : "Download finished — see Settings"
            }
            menu.items.first(where: { $0.identifier?.rawValue == "cancel-download" })?.isEnabled = downloadRunning && !readOnly
            return
        }
        menu.removeAllItems()
        let current = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: ""); current.isEnabled = false; menu.addItem(current)
        let next = NSMenuItem(title: menuScheduleTitle, action: nil, keyEquivalent: ""); next.isEnabled = false; menu.addItem(next)
        menu.addItem(.separator())
        let setItem = NSMenuItem(title: "Wallpaper Set", action: nil, keyEquivalent: "")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        for set in sets {
            let needsDownload = set.assets.contains { !$0.isDownloaded }
            let suffix = ready(set) ? "" : (needsDownload ? " — Download…" : " — Review…")
            let item = NSMenuItem(title: set.name + suffix, action: #selector(menuSelectedSet(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = set.id; item.state = selectedSet?.id == set.id ? .on : .off
            submenu.addItem(item)
        }
        setItem.submenu = submenu; menu.addItem(setItem)
        if downloadRunning {
            let name = sets.first { $0.id == downloadingSetID }?.name ?? "Set"
            let progress = downloadProgress.map { " (\($0.completedCount)/\($0.totalCount))" } ?? ""
            let item = NSMenuItem(title: "Downloading \(name)\(progress)…", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("download-status")
            item.isEnabled = false; menu.addItem(item)
            let cancel = NSMenuItem(title: "Cancel Download", action: #selector(menuCancelDownload), keyEquivalent: "")
            cancel.identifier = NSUserInterfaceItemIdentifier("cancel-download")
            cancel.target = self; cancel.isEnabled = !readOnly; menu.addItem(cancel)
        } else if let set = browsedSet, set.assets.contains(where: { !$0.isDownloaded }) {
            let download = NSMenuItem(title: "Download \(set.name)…", action: #selector(menuDownloadSet(_:)), keyEquivalent: "")
            download.target = self; download.representedObject = set.id; download.isEnabled = !readOnly
            menu.addItem(download)
        }
        let rotation = NSMenuItem(title: "Rotation Enabled", action: #selector(toggleRotation), keyEquivalent: "")
        rotation.target = self; rotation.state = configuration.rotationEnabled ? .on : .off; rotation.isEnabled = configuration.rotationEnabled || canEnableRequestedRotation
        menu.addItem(rotation)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settingsItem.target = self; menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Wallpaper Rotation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp; menu.addItem(quit)
    }
    @objc private func menuCancelDownload() { cancelDownload() }
    @objc private func menuDownloadSet(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { downloadSet(id) } }
    @objc private func menuSelectedSet(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { select(id) } }
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeStyle = .short; formatter.dateStyle = .none; return formatter.string(from: date)
    }
}
