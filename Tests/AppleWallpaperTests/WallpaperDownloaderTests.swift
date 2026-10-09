import AVFoundation
import Foundation
import Testing
@testable import AppleWallpaper

@Suite(.serialized)
@MainActor
struct WallpaperDownloaderTests {
    @Test func downloadsOnlyMissingSeriallyAndReportsCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = asset(in: directory)
        try movieContainerFixture().write(to: existing.videoURL)
        let first = asset(in: directory), second = asset(in: directory)
        let transport = FixtureMovieTransport()
        var validationCount = 0
        let downloader = WallpaperDownloader(transport: transport) { url in
            #expect(url.lastPathComponent.contains(".partial."))
            #expect(!FileManager.default.fileExists(atPath: first.videoURL.path) || validationCount == 1)
            validationCount += 1
        }
        let recorder = ProgressRecorder()
        try await downloader.download(assets: [existing, first, first, second]) { recorder.values.append($0) }
        #expect(transport.requests.count == 2)
        #expect(validationCount == 2)
        #expect(try Data(contentsOf: first.videoURL) == transport.body)
        #expect(try Data(contentsOf: second.videoURL) == transport.body)
        #expect(recorder.values.last?.completedCount == 2)
        #expect(recorder.values.last?.totalCount == 2)
        #expect(recorder.values.last?.fractionCompleted == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial.") })
    }

    @Test func rejectsUntrustedOrAbsentURLsBeforeTransport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureMovieTransport()
        let downloader = WallpaperDownloader(transport: transport, validateMovie: { _ in })
        for url in [nil, URL(string: "http://sylvan.apple.com/itunes-assets/test.mov"), URL(string: "https://sylvan.apple.com.attacker.test/itunes-assets/test.mov"), URL(string: "https://example.com/test.mov")] {
            await #expect(throws: (any Error).self) {
                try await downloader.download(assets: [asset(in: directory, source: url)]) { _ in }
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func badStatusFinalURLSizeAndValidationNeverInstall() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for failure in 0..<4 {
            let item = asset(in: directory)
            let transport = FixtureMovieTransport()
            if failure == 0 { transport.status = 206 }
            if failure == 1 { transport.finalURL = URL(string: "https://example.com/test.mov")! }
            if failure == 2 { transport.expectedLength = 100_000 }
            let downloader = WallpaperDownloader(transport: transport) { _ in
                if failure == 3 { throw WallpaperDownloadError.incompleteMovie }
            }
            await #expect(throws: (any Error).self) {
                try await downloader.download(assets: [item]) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: item.videoURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test func unknownLengthReportsIndeterminateProgressAndStillValidates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureMovieTransport(); transport.expectedLength = -1
        let recorder = ProgressRecorder()
        let downloader = WallpaperDownloader(transport: transport, validateMovie: { _ in })
        try await downloader.download(assets: [asset(in: directory)]) { recorder.values.append($0) }
        #expect(recorder.values.contains { $0.fractionCompleted == nil })
        #expect(recorder.values.last?.fractionCompleted == 1)
    }

    @Test func cancellationCleansStagingAndAllowsAnotherRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = asset(in: directory)
        let transport = FixtureMovieTransport()
        transport.afterWrite = { _ in try await Task.sleep(for: .seconds(30)) }
        let downloader = WallpaperDownloader(transport: transport, validateMovie: { _ in })
        let run = Task { try await downloader.download(assets: [item]) { _ in } }
        while transport.requests.isEmpty { await Task.yield() }
        downloader.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(transport.cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        transport.afterWrite = nil
        try await downloader.download(assets: [item]) { _ in }
        #expect(item.isDownloaded)
    }

    @Test func callerCancellationAlsoCleansStaging() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FixtureMovieTransport()
        transport.afterWrite = { _ in try await Task.sleep(for: .seconds(30)) }
        let downloader = WallpaperDownloader(transport: transport, validateMovie: { _ in })
        let run = Task { try await downloader.download(assets: [asset(in: directory)]) { _ in } }
        while transport.requests.isEmpty { await Task.yield() }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func preservesConcurrentMovieAndDanglingSymlink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = asset(in: directory)
        let external = movieContainerFixture() + movieAtom("free", payload: Data([42]))
        let transport = FixtureMovieTransport()
        let downloader = WallpaperDownloader(transport: transport) { _ in try external.write(to: item.videoURL) }
        try await downloader.download(assets: [item]) { _ in }
        #expect(try Data(contentsOf: item.videoURL) == external)
        let linkAsset = asset(in: directory)
        let target = directory.appendingPathComponent("missing.mov")
        let linkDownloader = WallpaperDownloader(transport: transport) { _ in
            try FileManager.default.createSymbolicLink(at: linkAsset.videoURL, withDestinationURL: target)
        }
        await #expect(throws: (any Error).self) { try await linkDownloader.download(assets: [linkAsset]) { _ in } }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkAsset.videoURL.path) == target.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains(".partial.") })
    }

    @Test func preexistingDanglingSymlinkIsPreservedWithoutDownloading() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = asset(in: directory), transport = FixtureMovieTransport()
        let target = directory.appendingPathComponent("missing.mov")
        try FileManager.default.createSymbolicLink(at: item.videoURL, withDestinationURL: target)
        let downloader = WallpaperDownloader(transport: transport, validateMovie: { _ in })
        await #expect(throws: (any Error).self) { try await downloader.download(assets: [item]) { _ in } }
        #expect(transport.requests.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: item.videoURL.path) == target.path)
    }

    @Test func failureRetainsEarlierCompletedMoviesOnly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = asset(in: directory), second = asset(in: directory)
        let transport = FixtureMovieTransport()
        var validations = 0
        let downloader = WallpaperDownloader(transport: transport) { _ in
            validations += 1
            if validations == 2 { throw WallpaperDownloadError.incompleteMovie }
        }
        await #expect(throws: (any Error).self) { try await downloader.download(assets: [first, second]) { _ in } }
        #expect(first.isDownloaded)
        #expect(!second.isDownloaded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [first.videoURL.lastPathComponent])
    }

    @Test func defaultValidationRejectsContainerWithInvalidMovieMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = asset(in: directory)
        let downloader = WallpaperDownloader(transport: FixtureMovieTransport())
        await #expect(throws: (any Error).self) { try await downloader.download(assets: [item]) { _ in } }
        #expect(!item.isDownloaded)
    }

    @Test func defaultValidationAcceptsLocallyGeneratedMovie() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = directory.appendingPathComponent("generated.mov")
        // Uncompressed passthrough avoids using a hardware encoder in sandboxed tests.
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var description: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                            formatDescriptionOut: &description) == noErr)
        let format = try #require(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                        formatDescription: format, sampleTiming: &timing,
                                                        sampleBufferOut: &sample) == noErr)
        let writer = try AVAssetWriter(url: generated, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        #expect(input.append(try #require(sample)))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        #expect(NativeMovieReadiness.isComplete(at: generated))
        try await WallpaperDownloader.validateMovie(generated)
        let transport = FixtureMovieTransport()
        transport.body = try Data(contentsOf: generated)
        let item = asset(in: directory)
        let downloader = WallpaperDownloader(transport: transport)
        try await downloader.download(assets: [item]) { _ in }
        #expect(item.isDownloaded)
    }

    @Test func burstProgressIsBoundedBeforeMainActorDelivery() {
        let gate = WallpaperByteProgressGate()
        var admitted = 0
        for milliseconds in 0..<1_000 {
            if gate.shouldEmit(at: Double(milliseconds) / 1_000) { admitted += 1 }
        }
        #expect(admitted <= 5)
        #expect(admitted > 0)
    }

    @Test func redirectAdmissionUsesSameStrictApplePolicy() {
        #expect(WallpaperDownloader.isTrustedAppleURL(URL(string: "https://sylvan.apple.com/itunes-assets/Aerials116/test.mov")!))
        for value in ["http://sylvan.apple.com/itunes-assets/test.mov", "https://sylvan.apple.com:444/itunes-assets/test.mov", "https://user@sylvan.apple.com/itunes-assets/test.mov", "https://sylvan.apple.com/other/test.mov", "https://sylvan.apple.com/itunes-assets/test.html", "https://sylvan.apple.com.evil.test/itunes-assets/test.mov"] {
            #expect(!WallpaperDownloader.isTrustedAppleURL(URL(string: value)!))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func asset(in directory: URL, source: URL? = URL(string: "https://sylvan.apple.com/itunes-assets/Aerials116/test.mov")) -> WallpaperAsset {
        let id = UUID().uuidString
        return .init(id: id, shotID: "fixture", name: "Fixture", previewURL: nil,
                     videoURL: directory.appendingPathComponent(id + ".mov"), downloadURL: source)
    }
}

@MainActor
private final class ProgressRecorder {
    var values: [WallpaperDownloadProgress] = []
}

@MainActor
private final class FixtureMovieTransport: WallpaperDownloadTransport {
    var body = movieContainerFixture()
    var requests: [URL] = []
    var status = 200
    var finalURL = URL(string: "https://sylvan.apple.com/itunes-assets/Aerials116/test.mov")!
    var expectedLength: Int64?
    var afterWrite: ((URL) async throws -> Void)?
    var cancelled = false

    func download(from source: URL, to staging: URL,
                  onBytes: @escaping @MainActor @Sendable (Int64, Int64) -> Void) async throws -> WallpaperTransferResponse {
        requests.append(source)
        try body.write(to: staging)
        onBytes(Int64(body.count), expectedLength ?? Int64(body.count))
        try await afterWrite?(staging)
        return .init(url: finalURL, statusCode: status, expectedLength: expectedLength ?? Int64(body.count))
    }

    func cancel() { cancelled = true }
}
