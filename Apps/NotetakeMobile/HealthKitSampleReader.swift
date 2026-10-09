import Foundation
import HealthKit
import NotetakeCore

/// HealthKitから心拍とHRV（SDNN）を読む。書き込みはしない。
/// `HKHealthStore`はthread-safeとAppleが文書化しているので、`@unchecked Sendable`にする
final class HealthKitSampleReader: HealthSampleReading, @unchecked Sendable {
    private let store = HKHealthStore()
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.heartRate), HKQuantityType(.heartRateVariabilitySDNN),
    ]

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    func needsAuthorizationRequest() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            return try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes) == .shouldRequest
        } catch {
            Diag.log("health: 許可の状態を読めません: \(error)")
            return false
        }
    }

    func heartRates(startMS: Int64, endMS: Int64) async throws -> [HeartRateSample] {
        let unit = HKUnit.count().unitDivided(by: .minute())
        return try await samples(.heartRate, startMS: startMS, endMS: endMS).map {
            HeartRateSample(at: Self.ms($0.startDate), bpm: $0.quantity.doubleValue(for: unit))
        }
    }

    func hrv(startMS: Int64, endMS: Int64) async throws -> [HRVSample] {
        let unit = HKUnit.secondUnit(with: .milli)
        return try await samples(.heartRateVariabilitySDNN, startMS: startMS, endMS: endMS).map {
            HRVSample(at: Self.ms($0.startDate), sdnnMS: $0.quantity.doubleValue(for: unit))
        }
    }

    private func samples(_ identifier: HKQuantityTypeIdentifier, startMS: Int64, endMS: Int64) async throws
        -> [HKQuantitySample]
    {
        let predicate = HKQuery.predicateForSamples(
            withStart: Date(timeIntervalSince1970: TimeInterval(startMS) / 1000),
            end: Date(timeIntervalSince1970: TimeInterval(endMS) / 1000))
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        do {
            return try await descriptor.result(for: store)
        } catch {
            Diag.log("health: \(identifier.rawValue)を読めません: \(error)")
            throw error
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
