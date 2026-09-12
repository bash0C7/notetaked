import Foundation
import Testing
@testable import NotetakeCore

private let fixtureStart = Date(timeIntervalSince1970: 1_700_000_000)

@Test func nextRotationAddsHoursInSeconds() {
    let next = RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: 24)
    #expect(next?.timeIntervalSince1970 == 1_700_086_400)
}

@Test func nextRotationFractionalHours() {
    let next = RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: 0.1)
    #expect(next?.timeIntervalSince1970 == 1_700_000_360)
}

@Test func nextRotationZeroIsNil() {
    #expect(RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: 0) == nil)
}

@Test func nextRotationNegativeIsNil() {
    #expect(RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: -1) == nil)
}

@Test func nextRotationNaNIsNil() {
    #expect(RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: .nan) == nil)
    #expect(RotationSchedule.normalizedIntervalHours(.nan) == 0)
}

@Test func nextRotationPositiveInfinityIsNil() {
    #expect(RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: .infinity) == nil)
    #expect(RotationSchedule.normalizedIntervalHours(.infinity) == 0)
}

@Test func nextRotationNegativeInfinityIsNil() {
    #expect(RotationSchedule.nextRotation(recordingStartedAt: fixtureStart, intervalHours: -.infinity) == nil)
    #expect(RotationSchedule.normalizedIntervalHours(-.infinity) == 0)
}

@Test func defaultIntervalHoursIs24() {
    #expect(RotationSchedule.defaultIntervalHours == 24)
}

@Test func normalizedIntervalHoursPassesThroughPositiveValues() {
    #expect(RotationSchedule.normalizedIntervalHours(24) == 24)
}
