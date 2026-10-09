import Foundation
import Testing
@testable import RotationCore

struct SolarScheduleTests {
    private let boston = Coordinate(latitude: 42.32, longitude: -71.09)
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    private func event(_ string: String, _ kind: SolarSchedule.SolarEvent.Kind) -> SolarSchedule.SolarEvent {
        .init(date: date(string), kind: kind)
    }

    @Test func testSixBoundariesAreHalfOpenElapsedHours() {
        let events = [event("2026-10-07T18:00:00Z", .sunset),
                      event("2026-10-08T06:00:00Z", .sunrise),
                      event("2026-10-08T18:00:00Z", .sunset),
                      event("2026-10-09T06:00:00Z", .sunrise)]
        let boundaries: [(String, WallpaperPhase, WallpaperPhase)] = [
            ("2026-10-08T05:00:00Z", .night, .evening),
            ("2026-10-08T06:00:00Z", .evening, .sunset),
            ("2026-10-08T07:00:00Z", .sunset, .day),
            ("2026-10-08T17:00:00Z", .day, .sunset),
            ("2026-10-08T18:00:00Z", .sunset, .evening),
            ("2026-10-08T19:00:00Z", .evening, .night)
        ]
        for (instant, before, after) in boundaries {
            let t = date(instant)
            #expect(SolarSchedule.snapshot(now: t.addingTimeInterval(-0.1), events: events).phase == before)
            let exact = SolarSchedule.snapshot(now: t, events: events)
            #expect(exact.phase == after)
            #expect(SolarSchedule.snapshot(now: t.addingTimeInterval(0.1), events: events).phase == after)
            #expect(exact.nextTransition!.date > t)
        }
        let today = SolarSchedule.snapshot(now: date("2026-10-08T00:00:00Z"), events: events)
            .transitions.filter { $0.date >= date("2026-10-08T00:00:00Z") && $0.date < date("2026-10-09T00:00:00Z") }
        #expect(today.count == 6)
    }

    @Test func testOverlappingShouldersUnionWithoutPhantomTransitions() {
        for duration in [5_400.0, 7_200.0] {
            let sunrise = date("2026-10-08T06:00:00Z")
            let sunset = sunrise.addingTimeInterval(duration)
            let shortDay: [SolarSchedule.SolarEvent] = [.init(date: sunrise, kind: .sunrise), .init(date: sunset, kind: .sunset)]
            for seconds in stride(from: 0.0, to: duration, by: 300) {
                #expect(SolarSchedule.snapshot(now: sunrise.addingTimeInterval(seconds), events: shortDay).phase == .sunset)
            }
            #expect(!(SolarSchedule.snapshot(now: sunrise, events: shortDay).transitions.contains { $0.phase == .day }))
            let nextRise = sunset.addingTimeInterval(duration)
            let shortNight: [SolarSchedule.SolarEvent] = [.init(date: sunset, kind: .sunset), .init(date: nextRise, kind: .sunrise)]
            for seconds in stride(from: 0.0, to: duration, by: 300) {
                #expect(SolarSchedule.snapshot(now: sunset.addingTimeInterval(seconds), events: shortNight).phase == .evening)
            }
            #expect(!(SolarSchedule.snapshot(now: sunset, events: shortNight).transitions.contains {
                $0.phase == .night && $0.date >= sunset && $0.date < nextRise
            }))
        }
    }

    @Test func testMidnightUsesAdjoiningDatesAndSortsInput() {
        let events = [event("2026-10-09T02:00:00Z", .sunrise), event("2026-10-08T23:30:00Z", .sunset)]
        let checks: [(String, WallpaperPhase)] = [
            ("2026-10-08T23:30:00Z", .evening), ("2026-10-09T00:29:59Z", .evening),
            ("2026-10-09T00:30:00Z", .night), ("2026-10-09T01:00:00Z", .evening),
            ("2026-10-09T02:00:00Z", .sunset)
        ]
        for (instant, phase) in checks {
            #expect(SolarSchedule.snapshot(now: date(instant), events: events).phase == phase)
        }
    }

    // Independent reference: USNO 2026 annual Boston table, coordinates 42.32,
    // -71.09, fixed UTC-4 (not a changing America/New_York time zone).
    // https://aa.usno.navy.mil/calculated/rstt/year?ID=AA&label=Boston%2C+MA&lat=42.32&lon=-71.09&submit=Get+Data&task=0&tz=4&tz_sign=-1&year=2026
    @Test func testIndependentUSNOSolarFixturesWithinTwoMinutes() {
        let fixtures = [
            ("2026-10-08T10:49:00Z", "2026-10-08T22:14:00Z"),
            ("2026-06-21T09:08:00Z", "2026-06-22T00:25:00Z"),
            ("2026-12-21T12:10:00Z", "2026-12-21T21:15:00Z"),
            ("2026-03-07T11:10:00Z", "2026-03-07T22:41:00Z"),
            ("2026-03-08T11:08:00Z", "2026-03-08T22:43:00Z"),
            ("2026-10-31T11:16:00Z", "2026-10-31T21:39:00Z"),
            ("2026-11-01T11:18:00Z", "2026-11-01T21:38:00Z")
        ]
        for (rise, set) in fixtures {
            let snapshot = try! SolarSchedule().evaluate(now: date(rise).addingTimeInterval(6 * 3_600), at: boston)
            let actualRise = snapshot.transitions.first { abs($0.date.timeIntervalSince(date(rise))) < 120 && $0.phase == .sunset }
            let actualSet = snapshot.transitions.first { abs($0.date.timeIntervalSince(date(set))) < 120 && $0.phase == .evening }
            #expect(actualRise != nil, Comment(rawValue: "Missing sunrise near \(rise)"))
            #expect(actualSet != nil, Comment(rawValue: "Missing sunset near \(set)"))
            #expect(abs(actualRise?.date.timeIntervalSince(date(rise)) ?? .infinity) < 120)
            #expect(abs(actualSet?.date.timeIntervalSince(date(set)) ?? .infinity) < 120)
        }
    }

    @Test func testDSTDisplayAndShouldersUseElapsedSeconds() throws {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "HH:mm"
        // The spring sunrise advances approximately one wall-clock hour while
        // its absolute solar time changes by just two minutes.
        #expect(formatter.string(from: date("2026-03-07T11:10:00Z")) == "06:10")
        #expect(formatter.string(from: date("2026-03-08T11:08:00Z")) == "07:08")
        #expect(formatter.string(from: date("2026-10-31T11:16:00Z")) == "07:16")
        #expect(formatter.string(from: date("2026-11-01T11:18:00Z")) == "06:18")
        let synthetic = [event("2026-03-08T07:30:00Z", .sunrise), event("2026-03-08T18:00:00Z", .sunset)]
        let snapshot = SolarSchedule.snapshot(now: date("2026-03-08T06:00:00Z"), events: synthetic)
        let evening = snapshot.transitions.first { $0.phase == .evening }!
        let sunrise = snapshot.transitions.first { $0.phase == .sunset }!
        #expect(sunrise.date.timeIntervalSince(evening.date) == 3_600)
        #expect(formatter.string(from: evening.date) == "01:30")
        #expect(formatter.string(from: sunrise.date) == "03:30")
        let fall = [event("2026-11-01T06:30:00Z", .sunrise), event("2026-11-01T18:00:00Z", .sunset)]
        let autumn = SolarSchedule.snapshot(now: date("2026-11-01T05:00:00Z"), events: fall)
        let a = autumn.transitions.first { $0.phase == .evening }!
        let b = autumn.transitions.first { $0.phase == .sunset }!
        #expect(b.date.timeIntervalSince(a.date) == 3_600)
        #expect(formatter.string(from: a.date) == "01:30")
        #expect(formatter.string(from: b.date) == "01:30")
    }

    @Test func testPolarSeasonsAndExactPolesHaveStrictlyFutureTransitions() throws {
        for latitude in [69.6492, 90.0, -90.0] {
            for instant in ["2026-06-21T12:00:00Z", "2026-12-21T12:00:00Z"] {
                let now = date(instant)
                let snapshot = try SolarSchedule().evaluate(now: now, at: Coordinate(latitude: latitude, longitude: 18.9553))
                let northernSummer = instant.contains("06-21") == (latitude > 0)
                #expect(snapshot.phase == (northernSummer ? .day : .night))
                #expect(snapshot.solarCondition == (northernSummer ? .polarDay : .polarNight))
                #expect(snapshot.nextTransition!.date > now)
                #expect(snapshot.nextTransition!.date.timeIntervalSince(now) < 370 * 86_400)
                #expect(snapshot.transitions.map(\.date) == snapshot.transitions.map(\.date).sorted())
            }
        }
    }

    @Test func testDateLineAndQuarterHourZoneRemainAbsolute() throws {
        for coordinate in [Coordinate(latitude: 1.87, longitude: -157.4),
                           Coordinate(latitude: -16.58, longitude: -179.9),
                           Coordinate(latitude: 27.7172, longitude: 85.3240)] {
            let now = date("2026-10-08T23:59:59Z")
            let snapshot = try SolarSchedule().evaluate(now: now, at: coordinate)
            #expect(snapshot.nextTransition!.date > now)
            #expect(!(snapshot.transitions.isEmpty))
            #expect(snapshot.solarCondition == .normal)
        }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        formatter.dateFormat = "HH:mm"
        #expect(formatter.string(from: date("2026-10-08T00:00:00Z")) == "05:45")
    }

    @Test func testInvalidCoordinatesAndDatesFail() {
        for coordinate in [Coordinate(latitude: .nan, longitude: 0), Coordinate(latitude: 91, longitude: 0),
                           Coordinate(latitude: 0, longitude: 181), Coordinate(latitude: 0, longitude: .infinity)] {
            #expect(throws: (any Error).self) { try SolarSchedule().evaluate(now: date("2026-10-08T12:00:00Z"), at: coordinate) }
        }
        #expect(throws: (any Error).self) { try SolarSchedule().evaluate(now: Date(timeIntervalSince1970: .infinity), at: boston) }
    }

    @Test func testWakeReevaluationSkipsMissedPhases() throws {
        let schedule = SolarSchedule()
        let before = try schedule.evaluate(now: date("2026-10-08T07:00:00Z"), at: boston)
        let wake = date("2026-10-08T20:00:00Z")
        let after = try schedule.evaluate(now: wake, at: boston)
        #expect(before.phase == .night)
        #expect(after.phase == .day)
        #expect(after.nextTransition!.date > wake)
        #expect(after.nextTransition?.phase == .sunset)
    }
}
