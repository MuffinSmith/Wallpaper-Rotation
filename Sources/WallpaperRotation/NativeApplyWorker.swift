import Foundation
import AppleWallpaper
import RotationCore

/// Owns the blocking adapter on a serial executor away from AppKit's main actor.
actor NativeApplyWorker {
    struct Result: Sendable {
        let transactionID: UUID
        let changedNative: Bool
        let receipt: OwnershipReceipt?
        let inspection: StoreInspection?
        let pending: PendingVisualVerification?
        let error: String?
    }
    struct Completion: Sendable {
        let pending: PendingVisualVerification?
        let error: String?
    }
    private let adapter: NativeWallpaperAdapter
    private let directory: URL
    private var lease: NativeOperationLease?
    private var transactionID: UUID?
    private var pendingURL: URL { directory.appendingPathComponent("pending-apply.json") }

    init(directory: URL = AppStorage.directory,
         adapterFactory: @Sendable () -> NativeWallpaperAdapter = { NativeWallpaperAdapter() }) {
        self.directory = directory
        adapter = adapterFactory()
    }

    func apply(assetID: String, previous: OwnershipReceipt?, transactionID: UUID) -> Result {
        guard self.transactionID == nil else {
            return Result(transactionID: transactionID, changedNative: false, receipt: nil, inspection: nil, pending: nil,
                          error: AppleWallpaperError.transactionBusy.localizedDescription)
        }
        self.transactionID = transactionID
        let startedAt = Date()
        var pending: PendingVisualVerification?
        var receipt: OwnershipReceipt?
        do {
            lease = try NativeOperationLease(directory: directory)
            if let previous, try !adapter.hasExternalChange(since: previous) {
                let current = try adapter.inspect()
                if !current.selections.isEmpty && current.selections.values.allSatisfy({ $0 == assetID }) {
                    return Result(transactionID: transactionID, changedNative: false, receipt: previous, inspection: current, pending: nil, error: nil)
                }
            }
            let prepared = PendingVisualVerification(assetID: assetID, startedAt: startedAt, receipt: nil,
                                                     previousReceipt: previous)
            try AppStorage.savePendingApply(prepared, to: pendingURL)
            pending = prepared
            receipt = try adapter.apply(assetID: assetID, previous: previous)
            let completed = PendingVisualVerification(assetID: assetID, startedAt: startedAt, receipt: receipt,
                                                      previousReceipt: previous)
            try AppStorage.savePendingApply(completed, to: pendingURL)
            pending = completed
            return Result(transactionID: transactionID, changedNative: true, receipt: receipt, inspection: try adapter.inspect(), pending: pending, error: nil)
        } catch {
            if receipt == nil, pending != nil { receipt = freshRecovery(assetID: assetID, startedAt: startedAt) }
            return Result(transactionID: transactionID, changedNative: receipt != nil, receipt: receipt, inspection: try? adapter.inspect(), pending: pending, error: error.localizedDescription)
        }
    }

    /// Keep the lease through durable ownership persistence; failure restores conditionally.
    func complete(_ result: Result, persisted: Bool) -> Completion {
        guard transactionID == result.transactionID else {
            return Completion(pending: result.pending, error: "Stale native transaction completion was ignored.")
        }
        defer { lease?.release(); lease = nil; transactionID = nil }
        var pending = result.pending
        do {
            if !persisted {
                if result.changedNative && result.error == nil, let receipt = result.receipt { _ = try adapter.restore(receipt) }
            } else if pending != nil && (result.error == nil || result.receipt != nil) {
                try AppStorage.removePendingApply(at: pendingURL)
                pending = nil
            }
            return Completion(pending: pending, error: nil)
        } catch { return Completion(pending: pending, error: error.localizedDescription) }
    }

    func inspect() throws -> StoreInspection { try adapter.inspect() }

    func restore(_ receipt: OwnershipReceipt, transactionID: UUID) throws -> RestoreResult {
        guard self.transactionID == nil else { throw AppleWallpaperError.transactionBusy }
        self.transactionID = transactionID
        do {
            lease = try NativeOperationLease(directory: directory)
            return try adapter.restore(receipt)
        } catch {
            lease?.release(); lease = nil; self.transactionID = nil
            throw error
        }
    }

    func completeRestore(transactionID: UUID) {
        guard self.transactionID == transactionID else { return }
        lease?.release(); lease = nil; self.transactionID = nil
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
}
