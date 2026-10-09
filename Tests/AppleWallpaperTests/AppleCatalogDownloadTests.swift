import Foundation
import Testing
@testable import AppleWallpaper

struct AppleCatalogDownloadTests {
    @Test func decodesNativeDownloadFieldAndRetainsAbsentURL() throws {
        try withMovieFixture { directory in
            let ids = (0..<4).map { _ in UUID().uuidString }
            let assets: [[String: Any]] = ids.enumerated().map { index, id in
                var entry: [String: Any] = ["id": id, "shotID": "FIXTURE_\(index)", "accessibilityLabel": "Fixture \(index)", "localizedNameKey": "Fixture", "subcategories": ["fixture"]]
                if index != 3 { entry["url-4K-SDR-240FPS"] = "https://sylvan.apple.com/itunes-assets/Aerials116/fixture\(index).mov" }
                return entry
            }
            let manifest: [String: Any] = ["version": 1, "assets": assets, "categories": [["subcategories": [["id": "fixture", "localizedNameKey": "AerialSubcategoryFixture"]]]]]
            let file = directory.appendingPathComponent("entries.json")
            try JSONSerialization.data(withJSONObject: manifest).write(to: file)
            let catalog = AppleSetCatalog(manifestURL: file, fallbackManifestURL: file, videosDirectory: directory, previewDirectory: directory)
            let set = try #require(catalog.discover().first)
            #expect(set.assets[0].downloadURL?.absoluteString == "https://sylvan.apple.com/itunes-assets/Aerials116/fixture0.mov")
            #expect(set.assets[3].downloadURL == nil)
            #expect(set.assets[0].videoURL == directory.appendingPathComponent(ids[0] + ".mov"))
        }
    }
}
