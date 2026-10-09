import Foundation

public enum WallpaperPhase: String, CaseIterable, Codable, Sendable {
    case day, sunset, evening, night
    public var title: String { rawValue.capitalized }
}

public struct Coordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct LocationFix: Codable, Equatable, Sendable {
    public let coordinate: Coordinate
    public let capturedAt: Date
    public let accuracyMeters: Double?
    public let source: String
    public init(coordinate: Coordinate, capturedAt: Date, accuracyMeters: Double? = nil, source: String = "Mac location") {
        self.coordinate = coordinate; self.capturedAt = capturedAt
        self.accuracyMeters = accuracyMeters; self.source = source
    }
}

public enum SolarCondition: String, Codable, Sendable { case normal, polarDay, polarNight }

public struct Transition: Equatable, Sendable {
    public let date: Date
    public let phase: WallpaperPhase
    public init(date: Date, phase: WallpaperPhase) { self.date = date; self.phase = phase }
}

public struct ScheduleSnapshot: Sendable {
    public let phase: WallpaperPhase
    public let nextTransition: Transition?
    public let transitions: [Transition]
    public let solarCondition: SolarCondition
    public init(phase: WallpaperPhase, nextTransition: Transition?, transitions: [Transition], solarCondition: SolarCondition = .normal) {
        self.phase = phase; self.nextTransition = nextTransition
        self.transitions = transitions; self.solarCondition = solarCondition
    }
}
