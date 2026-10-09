import CoreServices
import Foundation

/// Watches asset contents as well as directory entries. A directory-only vnode
/// source would miss an existing partial movie being completed in place.
@MainActor
final class AssetAvailabilityObserver {
    private let directories: [URL]
    private let onChange: @MainActor () -> Void
    private var stream: AvailabilityEventStream?
    private var watchedPaths: [String] = []
    private var debounce: Task<Void, Never>?
    private var running = false
    private var generation = UUID()
    private var needsRearm = false

    init(directories: [URL], onChange: @escaping @MainActor () -> Void) {
        self.directories = Array(Set(directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }))
            .sorted { $0.path < $1.path }
        self.onChange = onChange
    }

    func start() {
        guard !running else { return }
        running = true
        generation = UUID()
        rearmIfNeeded(force: true)
        scheduleRefresh()
    }

    func stop() {
        running = false
        generation = UUID()
        debounce?.cancel()
        debounce = nil
        stream?.stop()
        stream = nil
        watchedPaths = []
        needsRearm = false
    }

    deinit {
        debounce?.cancel()
        stream?.stop()
    }

    private func receive(paths: [String], mustRearm: Bool, generation token: UUID) {
        guard running, generation == token else { return }
        let relevant = mustRearm || paths.contains { path in
            let changed = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return directories.contains { directory in
                let wanted = directory.path
                return changed == wanted || changed.hasPrefix(wanted + "/")
                    || wanted.hasPrefix(changed == "/" ? "/" : changed + "/")
            }
        }
        guard relevant else { return }
        needsRearm = needsRearm || mustRearm
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard running, debounce == nil else { return }
        let token = generation
        // A fixed coalescing window bounds notification latency even if another
        // asset continues downloading. Nothing is scheduled while idle.
        debounce = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard let self, self.running, self.generation == token else { return }
            self.debounce = nil
            let force = self.needsRearm
            self.needsRearm = false
            self.rearmIfNeeded(force: force)
            self.onChange()
        }
    }

    private func rearmIfNeeded(force: Bool) {
        let roots = Set(directories.map { nearestExistingDirectory(to: $0).path })
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        // One ancestor stream path already covers any descendant path.
        let paths = roots.reduce(into: [String]()) { result, path in
            if !result.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                result.append(path)
            }
        }
        guard force || stream == nil || paths != watchedPaths else { return }
        stream?.stop()
        stream = nil
        watchedPaths = paths
        guard !paths.isEmpty else { return }
        let token = generation
        stream = AvailabilityEventStream(paths: paths) { [weak self] paths, mustRearm in
            Task { @MainActor [weak self] in
                self?.receive(paths: paths, mustRearm: mustRearm, generation: token)
            }
        }
    }

    private func nearestExistingDirectory(to url: URL) -> URL {
        var candidate = url
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}

/// The C callback owns a retained context with only a weak observer capture.
/// The stream is explicitly stopped before its context is released. This
/// holder may also be cleaned up by the observer's nonisolated deinitializer.
private final class AvailabilityEventStream: @unchecked Sendable {
    private var reference: FSEventStreamRef?

    init?(paths: [String], onEvent: @escaping @Sendable ([String], Bool) -> Void) {
        let callback = AvailabilityEventContext(onEvent: onEvent)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<AvailabilityEventContext>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<AvailabilityEventContext>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let reference = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let callback = Unmanaged<AvailabilityEventContext>.fromOpaque(context).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let rearmMask = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
            let mustRearm = (0..<count).contains { flags[$0] & rearmMask != 0 }
            callback.onEvent(paths, mustRearm)
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.12, flags) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(reference, .main)
        guard FSEventStreamStart(reference) else {
            FSEventStreamInvalidate(reference)
            FSEventStreamRelease(reference)
            return nil
        }
        self.reference = reference
    }

    func stop() {
        guard let reference else { return }
        self.reference = nil
        FSEventStreamStop(reference)
        FSEventStreamInvalidate(reference)
        FSEventStreamRelease(reference)
    }

    deinit { stop() }
}

private final class AvailabilityEventContext: @unchecked Sendable {
    let onEvent: @Sendable ([String], Bool) -> Void
    init(onEvent: @escaping @Sendable ([String], Bool) -> Void) { self.onEvent = onEvent }
}
