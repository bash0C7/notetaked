import CoreLocation
import Foundation
import NotetakeCore

/// appが動いている間（画面に出ている間と、収録している間）だけ位置を取り、登録地点への滞在を記録する。
/// Alwaysは求めない（userの決定）。収録中に画面を消した間は、`UIBackgroundModes`の`location`で更新を続ける
@MainActor
@Observable
final class PlaceMonitor: NSObject, CLLocationManagerDelegate {
    /// これより粗い位置は半径100mの地点の判定に使えないので、滞在に使わない
    private static let maxAccuracyM: CLLocationAccuracy = 100

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let log: PlaceStayLog
    @ObservationIgnored private let placesURL: URL
    @ObservationIgnored private var pendingLocation: CheckedContinuation<CLLocation?, Never>?
    @ObservationIgnored private var trackingWanted = false
    @ObservationIgnored private var current: PlaceStay?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var trackingSinceMS: Int64 = 0

    private(set) var places: [RegisteredPlace] = []
    private(set) var status: PlaceSourceStatus = .notDetermined
    private(set) var isReducedAccuracy = false
    private(set) var isTracking = false
    var lastError: String?

    init(directory: URL) {
        log = PlaceStayLog(url: directory.appendingPathComponent("place-stays.json"))
        placesURL = directory.appendingPathComponent("places.json")
        super.init()
        do {
            places = try JSONFile.read([RegisteredPlace].self, from: placesURL) ?? []
        } catch {
            Diag.log("place: 登録地点を読めません: \(error)")
            lastError = "登録地点を読めません: \(error.localizedDescription)"
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 30
        manager.pausesLocationUpdatesAutomatically = false
        refreshAuthorization()
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// 画面に出ているか収録している間はtrue。許可と登録地点がそろった時だけ、実際に更新を回す
    func setTracking(_ wanted: Bool) {
        trackingWanted = wanted
        applyTracking()
    }

    /// 地点を1つも登録していなければ、滞在を返さない
    func stays(startMS: Int64, endMS: Int64) throws -> [PlaceStay] {
        guard !places.isEmpty else { return [] }
        return try log.stays(startMS: startMS, endMS: endMS)
    }

    func registerCurrentLocation(name: String, radiusM: Double = 100) async -> Bool {
        guard pendingLocation == nil else { return false }
        let location = await withCheckedContinuation { continuation in
            pendingLocation = continuation
            manager.requestLocation()
        }
        guard let location else {
            lastError = "現在位置を取れませんでした"
            return false
        }
        places.append(
            RegisteredPlace(
                id: UUID(), name: name, latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, radiusM: radiusM))
        let saved = savePlaces()
        applyTracking()
        return saved
    }

    func removePlaces(at offsets: IndexSet) {
        places.remove(atOffsets: offsets)
        _ = savePlaces()
        applyTracking()
    }

    private func savePlaces() -> Bool {
        do {
            try JSONFile.write(places, to: placesURL)
            return true
        } catch {
            Diag.log("place: 登録地点を保存できません: \(error)")
            lastError = "登録地点を保存できません: \(error.localizedDescription)"
            return false
        }
    }

    private func refreshAuthorization() {
        switch manager.authorizationStatus {
        case .authorizedAlways: status = .always
        case .authorizedWhenInUse: status = .whenInUse
        case .denied: status = .denied
        case .restricted: status = .restricted
        case .notDetermined: status = .notDetermined
        @unknown default: status = .notDetermined
        }
        isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        applyTracking()
    }

    private func applyTracking() {
        let allowed = status == .whenInUse || status == .always
        let next = trackingWanted && allowed && !places.isEmpty
        guard next != isTracking else { return }
        isTracking = next
        if next {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            trackingSinceMS = Self.ms(Date())
            manager.startUpdatingLocation()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        return
                    }
                    self?.extendCurrent()
                }
            }
        } else {
            heartbeat?.cancel()
            heartbeat = nil
            extendCurrent()
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    private func observe(_ location: CLLocation) {
        guard isTracking, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maxAccuracyM else {
            return
        }
        let label = PlaceMatcher.label(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, places: places)
        write(
            PlaceTracking.observe(
                current, label: label, atMS: Self.ms(location.timestamp), trackingSinceMS: trackingSinceMS))
    }

    private func extendCurrent() {
        guard let stay = PlaceTracking.extend(current, toMS: Self.ms(Date())) else { return }
        write(stay)
    }

    private func write(_ stay: PlaceStay) {
        current = stay
        do {
            try log.record(stay, nowMS: Self.ms(Date()))
        } catch {
            Diag.log("place: 滞在を記録できません: \(error)")
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - CLLocationManagerDelegate（managerをmain threadで作るので、callbackもmain threadに届く）

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { refreshAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            pendingLocation?.resume(returning: locations.last)
            pendingLocation = nil
            for location in locations {
                observe(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let line = "place: 現在位置のエラー: \(error)"
        MainActor.assumeIsolated {
            Diag.log(line)
            pendingLocation?.resume(returning: nil)
            pendingLocation = nil
        }
    }
}
