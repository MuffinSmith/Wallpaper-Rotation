import AVFoundation
import Darwin
import Foundation

public enum WallpaperDownloadError: Error, LocalizedError {
    case busy
    case unavailable(String)
    case untrustedURL
    case invalidResponse
    case incompleteMovie
    case destinationOccupied

    public var errorDescription: String? {
        switch self {
        case .busy: "Another wallpaper download is already running."
        case .unavailable(let name): "Apple's catalog has no download URL for \(name)."
        case .untrustedURL: "The download was stopped because its URL is not a trusted Apple aerial location."
        case .invalidResponse: "Apple's server did not return a complete movie download."
        case .incompleteMovie: "The downloaded file is incomplete or is not a playable movie."
        case .destinationOccupied: "A file appeared at this movie's destination. It was preserved; try refreshing availability."
        }
    }
}

/// Downloads on explicit request. No wallpaper selection or ownership state is changed.
@MainActor
public final class WallpaperDownloader: WallpaperDownloading {
    private let transport: any WallpaperDownloadTransport
    private let validateMovie: @MainActor (URL) async throws -> Void
    private var activeTask: Task<Void, Error>?
    private var progressToken: UUID?

    public convenience init() {
        self.init(transport: AppleMovieTransport(), validateMovie: Self.validateMovie)
    }

    // Injection keeps regression tests on disposable files, without network traffic.
    init(transport: any WallpaperDownloadTransport,
         validateMovie: @escaping @MainActor (URL) async throws -> Void = WallpaperDownloader.validateMovie) {
        self.transport = transport
        self.validateMovie = validateMovie
    }

    public func download(assets: [WallpaperAsset],
                         onProgress: @escaping @MainActor @Sendable (WallpaperDownloadProgress) -> Void) async throws {
        guard activeTask == nil else { throw WallpaperDownloadError.busy }
        let task = Task { try await self.performDownload(assets: assets, onProgress: onProgress) }
        activeTask = task
        defer { activeTask = nil; progressToken = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    public func cancel() {
        activeTask?.cancel()
        progressToken = nil
        transport.cancel()
    }

    private func performDownload(assets: [WallpaperAsset],
                                 onProgress: @escaping @MainActor @Sendable (WallpaperDownloadProgress) -> Void) async throws {
        // Each unique destination is installed at most once, in catalog order.
        var seen = Set<URL>()
        let missing = assets.filter { seen.insert($0.videoURL).inserted && !$0.isDownloaded }
        let total = missing.count
        var completed = 0
        onProgress(.init(completedCount: 0, totalCount: total, fractionCompleted: total == 0 ? 1 : 0))
        for asset in missing {
            try Task.checkCancellation()
            // Apple may finish its own download after this run's initial inspection.
            if asset.isDownloaded {
                completed += 1
                onProgress(.init(completedCount: completed, totalCount: total, fractionCompleted: Double(completed) / Double(total)))
                continue
            }
            guard let source = asset.downloadURL else { throw WallpaperDownloadError.unavailable(asset.name) }
            guard Self.isTrustedAppleURL(source) else { throw WallpaperDownloadError.untrustedURL }
            guard asset.videoURL.isFileURL,
                  UUID(uuidString: asset.id) != nil,
                  asset.videoURL.lastPathComponent == asset.id + ".mov" else {
                throw WallpaperDownloadError.destinationOccupied
            }
            // Includes dangling symlinks: they must never be replaced.
            guard !Self.pathExists(asset.videoURL) else { throw WallpaperDownloadError.destinationOccupied }
            let directory = asset.videoURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staging = directory.appendingPathComponent(".\(asset.id)-\(UUID().uuidString).partial.mov")
            defer { try? FileManager.default.removeItem(at: staging) }
            let token = UUID()
            progressToken = token
            let completedBeforeTransfer = completed
            let response = try await transport.download(from: source, to: staging) { [weak self] bytes, expected in
                guard let self, self.progressToken == token else { return }
                let current = expected > 0 ? min(1, max(0, Double(bytes) / Double(expected))) : nil
                onProgress(.init(completedCount: completedBeforeTransfer, totalCount: total,
                                 fractionCompleted: current.map { (Double(completedBeforeTransfer) + $0) / Double(total) }))
            }
            progressToken = nil
            try Task.checkCancellation()
            guard Self.isTrustedAppleURL(response.url), response.statusCode == 200 else {
                throw WallpaperDownloadError.invalidResponse
            }
            let values = try staging.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            guard values.isRegularFile == true, size > 0,
                  response.expectedLength <= 0 || response.expectedLength == size else {
                throw WallpaperDownloadError.incompleteMovie
            }
            try await validateMovie(staging)
            try Task.checkCancellation()
            // RENAME_EXCL is atomic and cannot overwrite a concurrent file or symlink.
            let result = staging.withUnsafeFileSystemRepresentation { oldPath in
                asset.videoURL.withUnsafeFileSystemRepresentation { newPath in
                    renamex_np(oldPath!, newPath!, UInt32(RENAME_EXCL))
                }
            }
            if result != 0 {
                let code = errno
                if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                guard asset.isDownloaded else { throw WallpaperDownloadError.destinationOccupied }
            }
            completed += 1
            onProgress(.init(completedCount: completed, totalCount: total, fractionCompleted: Double(completed) / Double(total)))
        }
    }

    nonisolated static func isTrustedAppleURL(_ url: URL) -> Bool {
        // This is the sole host and movie path family in the current native manifest.
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "sylvan.apple.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.path.hasPrefix("/itunes-assets/") && url.path.lowercased().hasSuffix(".mov")
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { lstat($0!, &info) == 0 }
    }

    static func validateMovie(_ url: URL) async throws {
        // Seek over payloads instead of reading a potentially gigabyte-sized movie.
        guard NativeMovieReadiness.isComplete(at: url) else { throw WallpaperDownloadError.incompleteMovie }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard playable, duration.seconds.isFinite, duration.seconds > 0, !videos.isEmpty else {
            throw WallpaperDownloadError.incompleteMovie
        }
    }

}

struct WallpaperTransferResponse {
    let url: URL
    let statusCode: Int
    let expectedLength: Int64
}

@MainActor
protocol WallpaperDownloadTransport: AnyObject {
    func download(from source: URL, to staging: URL,
                  onBytes: @escaping @MainActor @Sendable (Int64, Int64) -> Void) async throws -> WallpaperTransferResponse
    func cancel()
}

@MainActor
private final class AppleMovieTransport: WallpaperDownloadTransport {
    private var session: URLSession?

    func download(from source: URL, to staging: URL,
                  onBytes: @escaping @MainActor @Sendable (Int64, Int64) -> Void) async throws -> WallpaperTransferResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        self.session = session
        defer { session.invalidateAndCancel(); self.session = nil }
        let delegate = AppleMovieDownloadDelegate(onBytes: onBytes)
        var request = URLRequest(url: source)
        // A full-body response allows an exact Content-Length/file-size check.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let finalURL = http.url,
              WallpaperDownloader.isTrustedAppleURL(finalURL), http.statusCode == 200 else {
            throw WallpaperDownloadError.invalidResponse
        }
        try FileManager.default.moveItem(at: temporary, to: staging)
        return .init(url: finalURL, statusCode: http.statusCode, expectedLength: http.expectedContentLength)
    }

    func cancel() { session?.invalidateAndCancel() }
}

private final class AppleMovieDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onBytes: @MainActor @Sendable (Int64, Int64) -> Void
    private let progressGate = WallpaperByteProgressGate()
    init(onBytes: @escaping @MainActor @Sendable (Int64, Int64) -> Void) { self.onBytes = onBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Pure URL policy; no main actor hop can delay redirect admission.
        let trusted = request.url.map(WallpaperDownloader.isTrustedAppleURL) ?? false
        completionHandler(trusted ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Throttle before scheduling main-actor work; Settings rebuilds on updates.
        guard progressGate.shouldEmit(at: ProcessInfo.processInfo.systemUptime) else { return }
        Task { @MainActor in onBytes(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// A delegate-queue gate bounds progress delivery to five updates per second.
/// Completion is reported separately after validation and atomic installation.
final class WallpaperByteProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: TimeInterval = -.infinity

    func shouldEmit(at time: TimeInterval) -> Bool {
        lock.withLock {
            guard time - previous >= 0.2 else { return false }
            previous = time
            return true
        }
    }
}
