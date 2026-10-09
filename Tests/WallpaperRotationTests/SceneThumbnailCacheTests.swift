import AppKit
import ImageIO
import Testing
@testable import WallpaperRotation

@Suite(.serialized)
@MainActor
struct SceneThumbnailCacheTests {
    private func writeFixture(to url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 2_000, height: 1_000,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func stillPreviewIsBoundedAndNeedsNoMovieOrNetwork() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let cache = SceneThumbnailCache()
        let menu = try #require(cache.image(at: url, size: .menu))
        #expect(menu.size == NSSize(width: 48, height: 30))
        let menuPixels = try #require(menu.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(menuPixels.width == 96)
        #expect(menuPixels.height == 60)
        let gallery = try #require(cache.image(at: url, size: .gallery))
        let galleryPixels = try #require(gallery.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(galleryPixels.width <= 420)
        #expect(galleryPixels.height <= 420)
        #expect(gallery.size.width / gallery.size.height == 2)
        #expect(cache.image(at: nil, size: .menu) == nil)
        #expect(cache.image(at: URL(string: "https://invalid.example/preview.png"), size: .menu) == nil)
    }

    @Test func missingPreviewRetriesAndCacheCanBeCleared() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-retry-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let cache = SceneThumbnailCache()
        #expect(cache.image(at: url, size: .menu, now: now) == nil)
        try writeFixture(to: url)
        #expect(cache.image(at: url, size: .menu, now: now.addingTimeInterval(1)) == nil)
        let image = try #require(cache.image(at: url, size: .menu, now: now.addingTimeInterval(5)))
        #expect(cache.image(at: url, size: .menu) === image)
        try FileManager.default.removeItem(at: url)
        cache.removeAll()
        #expect(cache.image(at: url, size: .menu) == nil)
        // An image already handed to a caller remains usable after the cache clears.
        #expect(image.size == NSSize(width: 48, height: 30))
    }
}
