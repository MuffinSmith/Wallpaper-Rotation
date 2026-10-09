import Darwin
import Foundation

/// Waits through launchd's relaunch gap before asking the next agent to reload.
/// The adapter invokes this synchronously on its native-operation worker, then
/// performs its existing selector readback. Absence alone never means success.
struct WallpaperAgentReloader {
    let run: (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> WallpaperProcessResult
    let now: () -> TimeInterval
    let pause: (TimeInterval) throws -> Void
    let checkCancellation: () throws -> Void
    let user: String
    let userID: String

    init(
        run: @escaping (String, [String], TimeInterval) throws -> WallpaperProcessResult = WallpaperReloadProcess.run,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @escaping (TimeInterval) throws -> Void = { Thread.sleep(forTimeInterval: $0) },
        checkCancellation: @escaping () throws -> Void = { try Task<Never, Never>.checkCancellation() },
        user: String = NSUserName(),
        userID: String = String(getuid())
    ) {
        self.run = run; self.now = now; self.pause = pause
        self.checkCancellation = checkCancellation; self.user = user; self.userID = userID
    }

    func reload(timeout: TimeInterval = 6) throws {
        let deadline = now() + max(0, timeout)
        while true {
            try checkCancellation()
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw AppleWallpaperError.reloadFailed("WallpaperAgent did not relaunch before the reload deadline")
            }
            let probe = try execute("/usr/bin/pgrep", ["-u", userID, "-x", "WallpaperAgent"],
                                    timeout: min(1, remaining))
            if probe.status == 0 {
                let identifiers = probe.output.split(whereSeparator: \.isWhitespace)
                guard !identifiers.isEmpty, identifiers.allSatisfy({ Int32($0).map { $0 > 0 } == true }) else {
                    throw AppleWallpaperError.reloadFailed("WallpaperAgent process probe returned invalid identifiers")
                }
                try checkCancellation()
                let terminationBudget = deadline - now()
                guard terminationBudget > 0 else {
                    throw AppleWallpaperError.reloadFailed("WallpaperAgent reload deadline expired before termination")
                }
                // Stop after the first successful TERM. Retry a failed command
                // only after confirming the agent disappeared in the probe gap.
                let termination = try execute("/usr/bin/killall", ["-u", user, "-TERM", "WallpaperAgent"],
                                              timeout: min(1, terminationBudget))
                if termination.status == 0 { return }
                guard termination.status == 1 else {
                    throw AppleWallpaperError.reloadFailed("WallpaperAgent termination failed (status \(termination.status))")
                }
                // The process can disappear between pgrep and killall. Only
                // confirmed absence permits another attempt; permission/other
                // failures against a still-running agent must surface as errors.
                try checkCancellation()
                let confirmationBudget = deadline - now()
                guard confirmationBudget > 0 else {
                    throw AppleWallpaperError.reloadFailed("WallpaperAgent disappeared before termination and did not reload before the deadline")
                }
                let confirmation = try execute("/usr/bin/pgrep", ["-u", userID, "-x", "WallpaperAgent"],
                                               timeout: min(1, confirmationBudget))
                guard confirmation.status == 1 else {
                    throw AppleWallpaperError.reloadFailed("WallpaperAgent termination failed; absence could not be confirmed (probe status \(confirmation.status))")
                }
            } else if probe.status != 1 {
                throw AppleWallpaperError.reloadFailed("WallpaperAgent process probe failed (status \(probe.status))")
            }
            try checkCancellation()
            let delay = min(0.1, max(0, deadline - now()))
            if delay > 0 { try pause(delay) }
        }
    }

    private func execute(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> WallpaperProcessResult {
        do { return try run(path, arguments, timeout) }
        catch is CancellationError { throw CancellationError() }
        catch WallpaperReloadProcessError.timedOut {
            throw AppleWallpaperError.reloadFailed("\(URL(fileURLWithPath: path).lastPathComponent) timed out")
        } catch {
            throw AppleWallpaperError.reloadFailed("could not run \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)")
        }
    }
}

struct WallpaperProcessResult {
    let status: Int32
    let output: String
}

enum WallpaperReloadProcessError: Error { case timedOut }

/// Bounded child execution. Only pgrep and killall are used by the reloader;
/// injection permits deterministic fixtures without invoking either live action.
enum WallpaperReloadProcess {
    static func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> WallpaperProcessResult {
        try Task<Never, Never>.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        do {
            while true {
                try Task<Never, Never>.checkCancellation()
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw WallpaperReloadProcessError.timedOut }
                if completed.wait(timeout: .now() + min(0.02, remaining)) == .success { break }
            }
        } catch {
            // Bound cleanup too, and reap a child that ignores TERM.
            if process.isRunning { process.terminate() }
            if completed.wait(timeout: .now() + 0.1) != .success {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = completed.wait(timeout: .now() + 0.2)
            }
            throw error
        }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        return .init(status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
    }
}
