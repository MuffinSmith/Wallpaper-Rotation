import Foundation
import Testing
import RotationCore

struct VerificationPolicyTests {
    private let build = "26A425"
    private let store = "fixture-store-v1"

    private func verification(schema: Int = 1, build: String? = nil, store: String? = nil,
                              at: String = "2026-10-08T18:01:00Z") -> NativeVerificationRecord {
        NativeVerificationRecord(schemaVersion: schema, osBuild: build ?? self.build,
                                 storeSchema: store ?? self.store, verifiedAt: at)
    }
    private func smoke(schema: Int = 1, build: String? = nil, store: String? = nil,
                       passed: Bool = true, at: String = "2026-10-08T18:00:00Z") -> NativeSmokeRecord {
        NativeSmokeRecord(schemaVersion: schema, osBuild: build ?? self.build,
                          storeSchema: store ?? self.store, passed: passed, checkedAt: at)
    }
    private func verified(_ record: NativeVerificationRecord, _ smoke: NativeSmokeRecord,
                          build: String? = nil, store: String? = nil) -> Bool {
        NativeVerificationPolicy.isVerified(record: record, smoke: smoke,
                                             currentOSBuild: build ?? self.build,
                                             currentStoreSchema: store ?? self.store)
    }
    private func smokePassed(_ record: NativeSmokeRecord, build: String? = nil, store: String? = nil) -> Bool {
        NativeVerificationPolicy.smokePassed(smoke: record, currentOSBuild: build ?? self.build,
                                             currentStoreSchema: store ?? self.store)
    }

    @Test func matchingPersistedFixturesEnableNativeActions() throws {
        // Hand-authored persisted records test the public Codable contract.
        let visualJSON = Data(#"{"schemaVersion":1,"osBuild":"26A425","storeSchema":"fixture-store-v1","verifiedAt":"2026-10-08T18:01:00Z"}"#.utf8)
        let smokeJSON = Data(#"{"schemaVersion":1,"osBuild":"26A425","storeSchema":"fixture-store-v1","passed":true,"checkedAt":"2026-10-08T18:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        let visual = try decoder.decode(NativeVerificationRecord.self, from: visualJSON)
        let check = try decoder.decode(NativeSmokeRecord.self, from: smokeJSON)
        #expect(verified(visual, check))
        #expect(smokePassed(check))
        let encoder = JSONEncoder()
        let visualRoundTrip = try decoder.decode(NativeVerificationRecord.self, from: encoder.encode(visual))
        let checkRoundTrip = try decoder.decode(NativeSmokeRecord.self, from: encoder.encode(check))
        #expect(verified(visualRoundTrip, checkRoundTrip))
    }

    @Test func failedSmokeRecheckRevokesPreviousVerification() {
        let previouslyApproved = verification()
        #expect(verified(previouslyApproved, smoke()))
        let failedRecheck = smoke(passed: false, at: "2026-10-08T18:02:00Z")
        #expect(!verified(previouslyApproved, failedRecheck))
        #expect(!smokePassed(failedRecheck))
        // Even a later visual record cannot approve a failed native check.
        #expect(!verified(verification(at: "2026-10-08T18:03:00Z"), failedRecheck))
    }

    @Test func successfulNewCheckStillRequiresNewVisualApproval() {
        let newerCheck = smoke(at: "2026-10-08T18:02:00Z")
        #expect(smokePassed(newerCheck))
        #expect(!verified(verification(), newerCheck))
        #expect(verified(verification(at: "2026-10-08T18:02:00Z"), newerCheck))
        #expect(verified(verification(at: "2026-10-08T18:03:00Z"), newerCheck))
    }

    @Test func OSUpdateAndIndependentRecordMismatchesDisableGate() {
        let updatedBuild = "26B123"
        #expect(!verified(verification(), smoke(), build: updatedBuild))
        #expect(!smokePassed(smoke(), build: updatedBuild))
        #expect(!verified(verification(build: updatedBuild), smoke()))
        #expect(!verified(verification(), smoke(build: updatedBuild)))
        #expect(verified(verification(build: updatedBuild), smoke(build: updatedBuild), build: updatedBuild))
        // Identity matching is exact, with no prefix or whitespace matching.
        #expect(!smokePassed(smoke(build: "26A425-extra")))
        #expect(!verified(verification(build: "26A425 "), smoke()))
    }

    @Test func StoreSchemaChangesRequireBothNewRecords() {
        let changedStore = "fixture-store-v2"
        #expect(!verified(verification(), smoke(), store: changedStore))
        #expect(!smokePassed(smoke(), store: changedStore))
        #expect(!verified(verification(store: changedStore), smoke()))
        #expect(!verified(verification(), smoke(store: changedStore)))
        #expect(verified(verification(store: changedStore), smoke(store: changedStore), store: changedStore))
    }

    @Test func unsupportedRecordVersionsFailClosed() {
        for schema in [-1, 0, 2, 99] {
            #expect(!verified(verification(schema: schema), smoke()))
            #expect(!verified(verification(), smoke(schema: schema)))
            #expect(!smokePassed(smoke(schema: schema)))
        }
    }

    @Test func invalidTimestampsFailBothRelevantGates() {
        for invalid in ["", "not-a-date", "2026-10-08", "2026-10-08T18:00:00", "2026-99-99T18:00:00Z"] {
            #expect(!verified(verification(at: invalid), smoke()))
            #expect(!verified(verification(), smoke(at: invalid)))
            #expect(!smokePassed(smoke(at: invalid)))
        }
    }

    @Test func chronologyComparesInstantsRatherThanTimestampStrings() {
        let check = smoke(at: "2026-10-08T18:00:00Z")
        #expect(verified(verification(at: "2026-10-08T11:00:00-07:00"), check))
        #expect(verified(verification(at: "2026-10-08T11:01:00-07:00"), check))
        #expect(!verified(verification(at: "2026-10-08T10:59:59-07:00"), check))
    }

    @Test func unknownOrEmptyCurrentOSBuildCannotVerifyItself() {
        for unknown in ["", " ", "\n", "unknown", " UNKNOWN "] {
            let visual = verification(build: unknown)
            let check = smoke(build: unknown)
            #expect(!verified(visual, check, build: unknown))
            #expect(!smokePassed(check, build: unknown))
        }
    }

    @Test func committedFirstWriteCanRecoverBeforeConfigurationSave() {
        let start = Date(timeIntervalSince1970: 1_791_480_000)
        // The pending marker exists, native storage and its receipt committed,
        // then the process ended before saving the app configuration receipt.
        #expect(RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                               startedAt: start, journalAssetID: "asset-day",
                                               journalOSBuild: build, journalModifiedAt: start.addingTimeInterval(0.25)))
        #expect(RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                               startedAt: start, journalAssetID: "asset-day",
                                               journalOSBuild: build, journalModifiedAt: start))
    }

    @Test func priorReceiptCannotMasqueradeAsFailedPendingWrite() {
        let start = Date(timeIntervalSince1970: 1_791_480_000)
        #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                startedAt: start, journalAssetID: "asset-day",
                                                journalOSBuild: build, journalModifiedAt: start.addingTimeInterval(-0.001)))
    }

    @Test func recoveryRejectsWrongAssetChangedOSAndMissingJournalTime() {
        let start = Date(timeIntervalSince1970: 1_791_480_000)
        let modified = start.addingTimeInterval(1)
        #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                startedAt: start, journalAssetID: "asset-night",
                                                journalOSBuild: build, journalModifiedAt: modified))
        #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: "26B123",
                                                startedAt: start, journalAssetID: "asset-day",
                                                journalOSBuild: build, journalModifiedAt: modified))
        #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                startedAt: start, journalAssetID: "asset-day",
                                                journalOSBuild: build, journalModifiedAt: nil))
        #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                startedAt: start, journalAssetID: "asset-day-extra",
                                                journalOSBuild: build, journalModifiedAt: modified))
    }

    @Test func recoveryRejectsUnknownBuildsAndNonfiniteDates() {
        let start = Date(timeIntervalSince1970: 1_791_480_000)
        for unknown in ["", " ", "unknown", " UNKNOWN "] {
            #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: unknown,
                                                    startedAt: start, journalAssetID: "asset-day",
                                                    journalOSBuild: unknown, journalModifiedAt: start))
        }
        for invalid in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity),
                        Date(timeIntervalSince1970: .nan)] {
            #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                    startedAt: invalid, journalAssetID: "asset-day",
                                                    journalOSBuild: build, journalModifiedAt: start))
            #expect(!RecoveryJournalPolicy.canAdopt(expectedAssetID: "asset-day", expectedOSBuild: build,
                                                    startedAt: start, journalAssetID: "asset-day",
                                                    journalOSBuild: build, journalModifiedAt: invalid))
        }
    }
}
