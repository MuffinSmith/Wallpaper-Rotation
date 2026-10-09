import Foundation
import Testing
import AppleWallpaper

struct NativeOperationLeaseTests {
    private func fixtureFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("native-operation-tests-\(UUID().uuidString)")
    }

    private func expectBusy(in directory: URL) {
        do {
            let unexpected = try NativeOperationLease(directory: directory)
            unexpected.release()
            Issue.record("A second operation acquired an already-held lease")
        } catch AppleWallpaperError.transactionBusy {
            // Exclusivity is a nonblocking failure, including within one process.
        } catch {
            Issue.record("Expected transactionBusy, received \(error)")
        }
    }

    @Test func leaseIsExclusiveUntilReleaseAndReleaseIsIdempotent() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try NativeOperationLease(directory: folder)
        defer { first.release() }
        expectBusy(in: folder)
        first.release()
        first.release()
        let second = try NativeOperationLease(directory: folder)
        defer { second.release() }
        // A stale release must not unlock a descriptor reused by the new lease.
        first.release()
        expectBusy(in: folder)
        second.release()
        let third = try NativeOperationLease(directory: folder)
        third.release()
    }

    @Test func droppingLeaseReleasesItsLockWithoutExplicitRelease() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var owner: NativeOperationLease? = try NativeOperationLease(directory: folder)
        weak let releasedOwner = owner
        #expect(owner != nil)
        expectBusy(in: folder)
        owner = nil
        #expect(releasedOwner == nil)
        let successor = try NativeOperationLease(directory: folder)
        defer { successor.release() }
        expectBusy(in: folder)
    }

    @Test func symbolicLinkLockIsRejectedWithoutChangingItsTarget() throws {
        let folder = fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("lease", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // This target is outside the lease directory but inside our disposable
        // fixture; the test never points a link at a user's files.
        let target = folder.appendingPathComponent("untouched-target.txt")
        let original = Data("fixture target must stay untouched".utf8)
        try original.write(to: target)
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        let lock = directory.appendingPathComponent("native-operation.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        do {
            let unexpected = try NativeOperationLease(directory: directory)
            unexpected.release()
            Issue.record("An operation followed a symbolic-link lock")
        } catch let error as POSIXError {
            #expect(error.code == .ELOOP)
        }
        #expect(try Data(contentsOf: target) == original)
        let after = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((after[.modificationDate] as? Date) == (before[.modificationDate] as? Date))
        #expect((after[.posixPermissions] as? NSNumber) == (before[.posixPermissions] as? NSNumber))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: lock.path) == target.path)
    }

    @Test func preparedSecondStageRetainsPreviousNightReceiptAndOriginalBaseline() throws {
        let baseline = ["/fixture/Desktop": Data("original desktop".utf8),
                        "/fixture/Idle": Data("original screen saver".utf8)]
        let nightValues = ["/fixture/Desktop": Data("night desktop".utf8),
                           "/fixture/Idle": Data("night screen saver".utf8)]
        let previousNight = OwnershipReceipt(originalValues: baseline, appliedValues: nightValues,
                                              assetID: "fixture-night", osBuild: "fixture-build")
        let startedAt = Date(timeIntervalSinceReferenceDate: 123.25)
        let prepared = PendingWallpaperOperation(assetID: "fixture-day", startedAt: startedAt,
                                                 receipt: nil, previousReceipt: previousNight)
        let decoder = JSONDecoder()
        let reloaded = try decoder.decode(PendingWallpaperOperation.self, from: JSONEncoder().encode(prepared))
        #expect(reloaded.schemaVersion == 1)
        #expect(reloaded.assetID == "fixture-day")
        #expect(reloaded.startedAt == startedAt)
        #expect(reloaded.receipt == nil)
        let fallback = try #require(reloaded.previousReceipt)
        #expect(fallback.assetID == "fixture-night")
        #expect(fallback.osBuild == "fixture-build")
        #expect(fallback.originalValues == baseline)
        #expect(fallback.appliedValues == nightValues)

        let dayValues = ["/fixture/Desktop": Data("day desktop".utf8),
                         "/fixture/Idle": Data("day screen saver".utf8)]
        let committedDay = OwnershipReceipt(originalValues: baseline, appliedValues: dayValues,
                                             assetID: "fixture-day", osBuild: "fixture-build")
        let committed = PendingWallpaperOperation(assetID: "fixture-day", startedAt: startedAt,
                                                  receipt: committedDay, previousReceipt: previousNight)
        let durable = try decoder.decode(PendingWallpaperOperation.self, from: JSONEncoder().encode(committed))
        #expect(durable.receipt?.originalValues == baseline)
        #expect(durable.receipt?.appliedValues == dayValues)
        #expect(durable.previousReceipt?.originalValues == baseline)
        #expect(durable.previousReceipt?.appliedValues == nightValues)
    }

    @Test func legacyPendingRecordWithoutPreviousReceiptStillDecodes() throws {
        // The default JSONEncoder Date representation is seconds since 2001.
        let legacy = Data(#"{"schemaVersion":1,"assetID":"fixture-night","startedAt":42,"receipt":{"originalValues":{"/fixture/Desktop":"b3JpZ2luYWw="},"appliedValues":{"/fixture/Desktop":"bmlnaHQ="},"assetID":"fixture-night","osBuild":"fixture-build"}}"#.utf8)
        let decoded = try JSONDecoder().decode(PendingWallpaperOperation.self, from: legacy)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.assetID == "fixture-night")
        #expect(decoded.startedAt == Date(timeIntervalSinceReferenceDate: 42))
        #expect(decoded.previousReceipt == nil)
        #expect(decoded.receipt?.originalValues == ["/fixture/Desktop": Data("original".utf8)])
        #expect(decoded.receipt?.appliedValues == ["/fixture/Desktop": Data("night".utf8)])
        #expect(decoded.receipt?.osBuild == "fixture-build")
    }
}
