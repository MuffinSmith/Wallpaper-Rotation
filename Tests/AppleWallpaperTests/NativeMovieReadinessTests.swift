import Foundation
import Testing
@testable import AppleWallpaper

@Suite(.serialized)
struct NativeMovieReadinessTests {
    @Test func completeMovieAndSymlinkAreReady() throws {
        try withMovieFixture { directory in
            let movie = directory.appendingPathComponent("complete.mov")
            try movieContainerFixture().write(to: movie)
            #expect(NativeMovieReadiness.isComplete(at: movie))
            let link = directory.appendingPathComponent("link.mov")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: movie)
            #expect(NativeMovieReadiness.isComplete(at: link))
        }
    }

    @Test func growingMovieAndInvalidAtomSizesAreNotReady() throws {
        try withMovieFixture { directory in
            let movie = directory.appendingPathComponent("growing.mov")
            let complete = movieContainerFixture()
            for count in [0, 7, 16, complete.count - 1] {
                try complete.prefix(count).write(to: movie)
                #expect(!NativeMovieReadiness.isComplete(at: movie))
            }
            for invalid in [movieAtom("ftyp", payload: Data(repeating: 0, count: 8)) + movieAtom("moov", payload: Data([0])),
                            movieAtom("ftyp", payload: Data(repeating: 0, count: 8)) + Data([0, 0, 0, 4]) + Data("mdat".utf8),
                            complete + Data([0]),
                            movieAtom("ftyp", payload: Data(repeating: 0, count: 8)) + Data([0, 0, 0, 0]) + Data("mdat".utf8) + movieAtom("moov", payload: Data([0]))] {
                try invalid.write(to: movie)
                #expect(!NativeMovieReadiness.isComplete(at: movie))
            }
        }
    }

    @Test func extendedSizesAreCheckedWithoutLoadingPayload() throws {
        try withMovieFixture { directory in
            let movie = directory.appendingPathComponent("extended.mov")
            let base = movieAtom("ftyp", payload: Data(repeating: 0, count: 8)) + movieAtom("moov", payload: Data([0]))
            let extended = Data([0, 0, 0, 1]) + Data("mdat".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 17]) + Data([0])
            try (base + extended).write(to: movie)
            #expect(NativeMovieReadiness.isComplete(at: movie))
            try (base + extended.dropLast()).write(to: movie)
            #expect(!NativeMovieReadiness.isComplete(at: movie))
            let overflow = Data([0, 0, 0, 1]) + Data("mdat".utf8) + Data(repeating: 255, count: 8)
            try (base + overflow).write(to: movie)
            #expect(!NativeMovieReadiness.isComplete(at: movie))
        }
    }

    @Test func missingDanglingLinkAndDirectoryAreNotReady() throws {
        try withMovieFixture { directory in
            let missing = directory.appendingPathComponent("missing.mov")
            #expect(!NativeMovieReadiness.isComplete(at: missing))
            let link = directory.appendingPathComponent("dangling.mov")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
            #expect(!NativeMovieReadiness.isComplete(at: link))
            #expect(!NativeMovieReadiness.isComplete(at: directory))
        }
    }

    @Test func pathologicalAtomCountIsBounded() throws {
        try withMovieFixture { directory in
            let movie = directory.appendingPathComponent("many.mov")
            var bytes = movieContainerFixture()
            for _ in 0..<10_000 { bytes.append(movieAtom("free")) }
            try bytes.write(to: movie)
            #expect(!NativeMovieReadiness.isComplete(at: movie))
        }
    }
}

func withMovieFixture(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

func movieAtom(_ kind: String, payload: Data = Data()) -> Data {
    let length = UInt32(8 + payload.count)
    return Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]) + Data(kind.utf8) + payload
}

func movieContainerFixture() -> Data {
    movieAtom("ftyp", payload: Data("qt  ".utf8) + Data(repeating: 0, count: 4))
        + movieAtom("wide") + movieAtom("mdat", payload: Data([1, 2, 3, 4]))
        + movieAtom("moov", payload: Data([0, 0, 0, 0]))
}
