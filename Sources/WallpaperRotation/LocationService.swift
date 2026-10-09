import CoreLocation
import Foundation
import RotationCore

/// Only asks Core Location for a single fix. Persistence and fallback belong to
/// the UI, which decides which lifecycle events merit another attempt.
@MainActor
final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onFix: ((LocationFix) -> Void)?
    var onStatus: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var inFlight = false
    private var awaitingAuthorization = false
    private var lastAutomaticAttempt: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func requestLocation(userInitiated: Bool = false) {
        guard !inFlight && !awaitingAuthorization else { return }
        let now = Date()
        if !userInitiated, let lastAutomaticAttempt,
           now.timeIntervalSince(lastAutomaticAttempt) >= 0,
           now.timeIntervalSince(lastAutomaticAttempt) < 15 * 60 { return }
        guard CLLocationManager.locationServicesEnabled() else {
            onStatus?("Mac location is disabled; using the saved location.")
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            guard userInitiated else {
                onStatus?("Choose Use Mac Location to allow location access, or enter coordinates.")
                return
            }
            awaitingAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !userInitiated { lastAutomaticAttempt = now }
            beginRequest()
        case .denied, .restricted:
            onStatus?("Mac location access is unavailable; using the saved location or manual coordinates.")
        @unknown default:
            onStatus?("Mac location is unavailable; using the saved location.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingAuthorization else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            awaitingAuthorization = false
            beginRequest()
        case .denied, .restricted:
            awaitingAuthorization = false
            onStatus?("Mac location access was denied; enter coordinates or use the saved location.")
        default: break
        }
    }

    private func beginRequest() {
        guard !inFlight else { return }
        inFlight = true
        onStatus?("Getting Mac location…")
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard inFlight else { return }
        inFlight = false
        let now = Date()
        guard let fix = locations.filter({ Self.valid($0, now: now) }).max(by: { $0.timestamp < $1.timestamp }) else {
            onStatus?("Mac location did not provide a recent valid fix; using the saved location.")
            return
        }
        onFix?(LocationFix(coordinate: Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                           capturedAt: fix.timestamp, accuracyMeters: fix.horizontalAccuracy))
        onStatus?("Following Mac location")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard inFlight else { return }
        inFlight = false
        onStatus?("Mac location could not be refreshed; using the saved location. Try again after wake or with Use Mac Location.")
    }

    private static func valid(_ location: CLLocation, now: Date) -> Bool {
        Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude).isValid
            && location.horizontalAccuracy.isFinite && (0...50_000).contains(location.horizontalAccuracy)
            && location.timestamp.timeIntervalSince1970.isFinite
            && location.timestamp >= now.addingTimeInterval(-6 * 3_600)
            && location.timestamp <= now.addingTimeInterval(5 * 60)
    }
}
