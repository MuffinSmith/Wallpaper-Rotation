import Foundation

/// Reads only top-level QuickTime/ISO-BMFF atom headers, seeking over media bytes.
/// This catches growing Apple cache files whose declared media or movie atoms
/// extend beyond EOF. It follows Apple's legitimate cached-movie symlinks.
public enum NativeMovieReadiness {
    public static func isComplete(at url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.isFileURL,
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
        return (try? inspect(resolved)) == true
    }

    private static func inspect(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        var offset: UInt64 = 0
        var hasType = false
        var hasMovie = false
        var hasMedia = false
        var atomCount = 0
        while offset < size {
            atomCount += 1
            guard atomCount <= 10_000, size - offset >= 8 else { return false }
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 8), header.count == 8 else { return false }
            let length32 = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let kind = String(decoding: header.suffix(4), as: UTF8.self)
            var length = length32
            var headerLength: UInt64 = 8
            if length32 == 1 {
                guard size - offset >= 16,
                      let extended = try file.read(upToCount: 8), extended.count == 8 else { return false }
                length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerLength = 16
            } else if length32 == 0 {
                // An open-ended atom cannot establish completeness while Apple is writing.
                return false
            }
            guard length >= headerLength, length <= size - offset else { return false }
            if kind == "ftyp", length >= headerLength + 8 { hasType = true }
            if kind == "moov", length > headerLength { hasMovie = true }
            if kind == "mdat", length > headerLength { hasMedia = true }
            offset += length
        }
        // Notice truncation or growth during inspection rather than reporting stale readiness.
        let finalSize = try file.seekToEnd()
        return hasType && hasMovie && hasMedia && finalSize == size
    }
}
