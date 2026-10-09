import Foundation

public enum SolarScheduleError: Error {
    case invalidCoordinate
    case invalidDate
}

/// An offline schedule whose shoulders are elapsed hours, independent of DST.
public struct SolarSchedule: Sendable {
    public init() {}

    public func evaluate(now: Date, at coordinate: Coordinate) throws -> ScheduleSnapshot {
        guard coordinate.isValid else { throw SolarScheduleError.invalidCoordinate }
        guard now.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince1970) < 300_000_000_000 else {
            throw SolarScheduleError.invalidDate
        }
        let day = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        var events = (-3...3).flatMap {
            Self.events(dayStarting: Date(timeIntervalSince1970: day + Double($0) * 86_400), at: coordinate)
        }
        // During polar seasons, find actual adjoining crossings rather than
        // scheduling a repeating check or inventing sunrise/sunset times.
        if !events.contains(where: { $0.date <= now }) {
            for offset in 4...370 {
                let found = Self.events(dayStarting: Date(timeIntervalSince1970: day - Double(offset) * 86_400), at: coordinate)
                events.append(contentsOf: found)
                if !found.isEmpty { break }
            }
        }
        if !events.contains(where: { $0.date > now.addingTimeInterval(3_600) }) {
            for offset in 4...370 {
                let found = Self.events(dayStarting: Date(timeIntervalSince1970: day + Double(offset) * 86_400), at: coordinate)
                events.append(contentsOf: found)
                if !found.isEmpty { break }
            }
        }
        events.sort { $0.date < $1.date }
        let daylight = Self.horizonValue(at: now, coordinate: coordinate) >= 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let localDay = calendar.dateInterval(of: .day, for: now)
        let hasEventToday = events.contains { event in
            guard let localDay else { return false }
            return event.date >= localDay.start && event.date < localDay.end
        }
        return Self.snapshot(now: now, events: events, fallbackDaylight: daylight,
                             condition: hasEventToday ? .normal : (daylight ? .polarDay : .polarNight))
    }

    internal struct SolarEvent: Equatable, Sendable {
        enum Kind: Sendable { case sunrise, sunset }
        let date: Date
        let kind: Kind
    }

    internal static func snapshot(now: Date, events: [SolarEvent], fallbackDaylight: Bool = false,
                                  condition: SolarCondition = .normal) -> ScheduleSnapshot {
        let sorted = events.sorted { $0.date < $1.date }
        let candidates = sorted.flatMap { event in
            [event.date.addingTimeInterval(-3_600), event.date, event.date.addingTimeInterval(3_600)]
        }.sorted()
        var transitions: [Transition] = []
        for date in candidates {
            guard transitions.last?.date != date else { continue }
            let before = phase(at: date.addingTimeInterval(-0.001), events: sorted, fallbackDaylight: fallbackDaylight)
            let after = phase(at: date, events: sorted, fallbackDaylight: fallbackDaylight)
            if before != after { transitions.append(Transition(date: date, phase: after)) }
        }
        return ScheduleSnapshot(phase: phase(at: now, events: sorted, fallbackDaylight: fallbackDaylight),
                                nextTransition: transitions.first { $0.date > now },
                                transitions: transitions, solarCondition: condition)
    }

    private static func phase(at date: Date, events: [SolarEvent], fallbackDaylight: Bool) -> WallpaperPhase {
        let previous = events.last { $0.date <= date }
        let next = events.first { $0.date > date }
        let daylight = previous.map { $0.kind == .sunrise }
            ?? next.map { $0.kind == .sunset } ?? fallbackDaylight
        if daylight {
            let justRose = previous?.kind == .sunrise && date.timeIntervalSince(previous!.date) < 3_600
            let settingSoon = next?.kind == .sunset && next!.date.timeIntervalSince(date) <= 3_600
            return justRose || settingSoon ? .sunset : .day
        }
        let justSet = previous?.kind == .sunset && date.timeIntervalSince(previous!.date) < 3_600
        let risingSoon = next?.kind == .sunrise && next!.date.timeIntervalSince(date) <= 3_600
        return justSet || risingSoon ? .evening : .night
    }

    /// Roots of the geometric solar-centre altitude at -0.833 degrees. Daily
    /// extrema are included so even a very short polar day/night is bracketed.
    internal static func events(dayStarting start: Date, at coordinate: Coordinate) -> [SolarEvent] {
        let end = start.addingTimeInterval(86_400)
        let noonTerms = terms(at: start.addingTimeInterval(43_200))
        var solarNoon = (720 - 4 * coordinate.longitude - noonTerms.equationOfTime) * 60
        solarNoon = solarNoon.truncatingRemainder(dividingBy: 86_400)
        if solarNoon < 0 { solarNoon += 86_400 }
        var midnight = (solarNoon + 43_200).truncatingRemainder(dividingBy: 86_400)
        if midnight < 0 { midnight += 86_400 }
        var points = (0...4).map { start.addingTimeInterval(Double($0) * 21_600) }
        for (centre, maximum) in [(solarNoon, true), (midnight, false)] {
            let extremum = extremum(near: start.addingTimeInterval(centre), at: coordinate, maximum: maximum)
            if extremum > start && extremum < end { points.append(extremum) }
        }
        points.sort()
        var result: [SolarEvent] = []
        for (left, right) in zip(points, points.dropFirst()) {
            let a = horizonValue(at: left, coordinate: coordinate)
            let b = horizonValue(at: right, coordinate: coordinate)
            guard (a < 0 && b >= 0) || (a >= 0 && b < 0) else { continue }
            var lower = left
            var upper = right
            let rising = a < b
            while upper.timeIntervalSince(lower) > 0.01 {
                let middle = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
                if (horizonValue(at: middle, coordinate: coordinate) >= 0) == rising {
                    upper = middle
                } else {
                    lower = middle
                }
            }
            let date = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
            if result.last.map({ abs($0.date.timeIntervalSince(date)) < 0.02 }) != true {
                result.append(SolarEvent(date: date, kind: rising ? .sunrise : .sunset))
            }
        }
        return result
    }

    private static func extremum(near centre: Date, at coordinate: Coordinate, maximum: Bool) -> Date {
        var lower = centre.addingTimeInterval(-10_800)
        var upper = centre.addingTimeInterval(10_800)
        // Ternary search of a smooth daily extremum; monotonic polar intervals
        // settle at an endpoint, while the regular grid still finds crossings.
        for _ in 0..<40 {
            let third = upper.timeIntervalSince(lower) / 3
            let a = lower.addingTimeInterval(third)
            let b = upper.addingTimeInterval(-third)
            let av = horizonValue(at: a, coordinate: coordinate)
            let bv = horizonValue(at: b, coordinate: coordinate)
            if (av < bv) == maximum { lower = a } else { upper = b }
        }
        return lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
    }

    private static func horizonValue(at date: Date, coordinate: Coordinate) -> Double {
        let solar = terms(at: date)
        let minutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        let solarMinutes = minutes + solar.equationOfTime + 4 * coordinate.longitude
        let hourAngle = radians(solarMinutes / 4 - 180)
        let latitude = radians(coordinate.latitude)
        return sin(latitude) * sin(solar.declination)
            + cos(latitude) * cos(solar.declination) * cos(hourAngle) - sin(radians(-0.833))
    }

    /// NOAA's full Julian-century solar-position equations (Meeus).
    /// https://gml.noaa.gov/grad/solcalc/calcdetails.html
    private static func terms(at date: Date) -> (declination: Double, equationOfTime: Double) {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525
        let longitude = normalizedDegrees(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let anomaly = radians(357.52911 + t * (35_999.05029 - 0.0001537 * t))
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let centre = sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * t) + sin(3 * anomaly) * 0.000289
        let omega = radians(125.04 - 1934.136 * t)
        let apparentLongitude = radians(longitude + centre - 0.00569 - 0.00478 * sin(omega))
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let obliquity = radians(23 + (26 + seconds / 60) / 60 + 0.00256 * cos(omega))
        let declination = asin(sin(obliquity) * sin(apparentLongitude))
        let y = pow(tan(obliquity / 2), 2)
        let l = radians(longitude)
        let equation = y * sin(2 * l) - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * l)
            - 0.5 * y * y * sin(4 * l) - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)
        return (declination, equation * 180 / .pi * 4)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func normalizedDegrees(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }
}
