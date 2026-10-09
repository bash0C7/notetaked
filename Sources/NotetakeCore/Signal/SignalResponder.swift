import Foundation

/// HealthKitの読み取り。iPhone appがHealthKitで実装し、テストはfakeで差し替える
public protocol HealthSampleReading: Sendable {
    func heartRates(startMS: Int64, endMS: Int64) async throws -> [HeartRateSample]
    func hrv(startMS: Int64, endMS: Int64) async throws -> [HRVSample]
    /// 許可をまだ一度も求めていない
    func needsAuthorizationRequest() async -> Bool
}

/// iPhoneが要求へ答える。測定値は10分ごとに集計してから返し、生の測定値はiPhoneの外へ出さない
public enum SignalResponder {
    public static func respond(
        to request: SignalRequestMessage, health: some HealthSampleReading, stays: [PlaceStay],
        placeStatus: PlaceSourceStatus
    ) async -> SignalResponseMessage {
        var heartRates: [HeartRateSample] = []
        var hrv: [HRVSample] = []
        let hrStatus: HealthSourceStatus
        let hrvStatus: HealthSourceStatus
        if await health.needsAuthorizationRequest() {
            hrStatus = .notRequested
            hrvStatus = .notRequested
        } else {
            do {
                heartRates = try await health.heartRates(startMS: request.startMS, endMS: request.endMS)
                hrStatus = heartRates.isEmpty ? .empty : .ok
            } catch {
                hrStatus = .unavailable
            }
            do {
                hrv = try await health.hrv(startMS: request.startMS, endMS: request.endMS)
                hrvStatus = hrv.isEmpty ? .empty : .ok
            } catch {
                hrvStatus = .unavailable
            }
        }
        return SignalResponseMessage(
            id: request.id, prefix: request.prefix,
            sources: SignalSources(hr: hrStatus, hrv: hrvStatus, place: placeStatus),
            buckets: SignalBucketing.buckets(
                startMS: request.startMS, endMS: request.endMS, bucketMS: request.bucketMS,
                heartRates: heartRates, hrv: hrv, stays: stays))
    }
}
