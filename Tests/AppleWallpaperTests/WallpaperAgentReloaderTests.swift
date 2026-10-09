import Foundation
import Testing
@testable import AppleWallpaper

@Suite(.serialized)
struct WallpaperAgentReloaderTests {
    @Test func initiallyPresentAgentReceivesOneTermination() throws {
        let fixture = ReloadFixture(results: [.init(status: 0, output: "123\n"), .init(status: 0, output: "")])
        try fixture.reloader.reload()
        #expect(fixture.calls.map(\.path) == ["/usr/bin/pgrep", "/usr/bin/killall"])
        #expect(fixture.calls[0].arguments == ["-u", "501", "-x", "WallpaperAgent"])
        #expect(fixture.calls[1].arguments == ["-u", "fixture", "-TERM", "WallpaperAgent"])
        #expect(fixture.pauses.isEmpty)
    }

    @Test func relaunchGapWaitsThenTerminatesOnceAndStops() throws {
        let fixture = ReloadFixture(results: [.init(status: 1, output: ""), .init(status: 1, output: ""),
                                               .init(status: 0, output: "456\n"), .init(status: 0, output: "")])
        try fixture.reloader.reload()
        #expect(fixture.calls.filter { $0.path.hasSuffix("pgrep") }.count == 3)
        #expect(fixture.calls.filter { $0.path.hasSuffix("killall") }.count == 1)
        #expect(fixture.pauses.count == 2)
        #expect(fixture.time >= 0.2)
    }

    @Test func exhaustedMissingAgentFailsWithoutTermination() {
        let fixture = ReloadFixture(results: [], fallback: .init(status: 1, output: ""))
        #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload(timeout: 0.25) }
        #expect(fixture.calls.allSatisfy { $0.path.hasSuffix("pgrep") })
        #expect(fixture.time == 0.25)
        #expect(fixture.calls.count <= 3)
    }

    @Test func invalidProbeOrOtherFailureDoesNotBecomeMissingRetry() {
        for response in [WallpaperProcessResult(status: 2, output: ""), .init(status: 0, output: ""),
                         .init(status: 0, output: "not-a-pid"), .init(status: 0, output: "0\n")] {
            let fixture = ReloadFixture(results: [response])
            #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload() }
            #expect(fixture.calls.count == 1)
            #expect(fixture.pauses.isEmpty)
        }
    }

    @Test func terminationFailureNeverRetriesOrKillsAnotherRespawn() {
        let fixture = ReloadFixture(results: [.init(status: 0, output: "123\n"), .init(status: 1, output: ""),
                                               .init(status: 0, output: "123\n")])
        #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload() }
        #expect(fixture.calls.count == 3)
        #expect(fixture.calls.filter { $0.path.hasSuffix("killall") }.count == 1)
        #expect(fixture.pauses.isEmpty)
    }

    @Test func probeTerminationRaceRetriesOnlyAfterConfirmedAbsence() throws {
        let fixture = ReloadFixture(results: [.init(status: 0, output: "123\n"), .init(status: 1, output: ""),
                                               .init(status: 1, output: ""), .init(status: 0, output: "456\n"),
                                               .init(status: 0, output: "")])
        try fixture.reloader.reload()
        #expect(fixture.calls.map(\.path) == ["/usr/bin/pgrep", "/usr/bin/killall", "/usr/bin/pgrep", "/usr/bin/pgrep", "/usr/bin/killall"])
        #expect(fixture.pauses.count == 1)
    }

    @Test func terminationOtherErrorDoesNotRetryEvenIfAgentCouldDisappear() {
        let fixture = ReloadFixture(results: [.init(status: 0, output: "123\n"), .init(status: 2, output: "")])
        #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload() }
        #expect(fixture.calls.count == 2)
        #expect(fixture.pauses.isEmpty)
    }

    @Test func childTimeoutOrLaunchFailureStopsImmediately() {
        for error in [WallpaperReloadProcessError.timedOut as any Error, CocoaError(.fileNoSuchFile)] {
            let fixture = ReloadFixture(results: [])
            fixture.executionError = error
            #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload() }
            #expect(fixture.calls.count == 1)
            #expect(fixture.pauses.isEmpty)
        }
    }

    @Test func cancellationWhileWaitingDoesNotTerminateAgent() {
        let fixture = ReloadFixture(results: [], fallback: .init(status: 1, output: ""))
        fixture.cancelAt = 0.1
        #expect(throws: CancellationError.self) { try fixture.reloader.reload() }
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.allSatisfy { $0.path.hasSuffix("pgrep") })
    }

    @Test func cancellationAtProcessBoundaryPropagates() {
        let fixture = ReloadFixture(results: [])
        fixture.executionError = CancellationError()
        #expect(throws: CancellationError.self) { try fixture.reloader.reload() }
        #expect(fixture.calls.count == 1)
    }

    @Test func probeConsumingDeadlineCannotLeadToLateTermination() {
        let fixture = ReloadFixture(results: [.init(status: 0, output: "123\n")])
        fixture.executionDuration = 0.5
        #expect(throws: AppleWallpaperError.self) { try fixture.reloader.reload(timeout: 0.5) }
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls[0].timeout == 0.5)
    }

    @Test func boundedProcessRunnerTerminatesDisposableTimedOutChild() {
        let before = ProcessInfo.processInfo.systemUptime
        #expect(throws: WallpaperReloadProcessError.self) {
            _ = try WallpaperReloadProcess.run("/bin/sleep", ["5"], 0.03)
        }
        #expect(ProcessInfo.processInfo.systemUptime - before < 1)
    }

    @Test func processRunnerCancellationStopsDisposableChildPromptly() async throws {
        let before = ProcessInfo.processInfo.systemUptime
        let execution = Task.detached { try WallpaperReloadProcess.run("/bin/sleep", ["5"], 2) }
        try await Task.sleep(for: .milliseconds(30))
        execution.cancel()
        await #expect(throws: CancellationError.self) { try await execution.value }
        #expect(ProcessInfo.processInfo.systemUptime - before < 1)
    }

    @Test func processRunnerCapturesExitStatusAndOutput() throws {
        let result = try WallpaperReloadProcess.run("/usr/bin/printf", ["123\n"], 1)
        #expect(result.status == 0)
        #expect(result.output == "123\n")
    }
}

private final class ReloadFixture {
    struct Call { let path: String; let arguments: [String]; let timeout: TimeInterval }
    var results: [WallpaperProcessResult]
    let fallback: WallpaperProcessResult
    var calls: [Call] = []
    var pauses: [TimeInterval] = []
    var time: TimeInterval = 0
    var executionDuration: TimeInterval = 0
    var executionError: (any Error)?
    var cancelAt: TimeInterval?

    init(results: [WallpaperProcessResult], fallback: WallpaperProcessResult = .init(status: 2, output: "")) {
        self.results = results; self.fallback = fallback
    }

    var reloader: WallpaperAgentReloader {
        WallpaperAgentReloader(run: { path, arguments, timeout in
            self.calls.append(.init(path: path, arguments: arguments, timeout: timeout))
            self.time += self.executionDuration
            if let error = self.executionError { throw error }
            return self.results.isEmpty ? self.fallback : self.results.removeFirst()
        }, now: { self.time }, pause: { duration in self.pauses.append(duration); self.time += duration },
        checkCancellation: {
            if let cancelAt = self.cancelAt, self.time >= cancelAt { throw CancellationError() }
        }, user: "fixture", userID: "501")
    }
}
