import Testing
@testable import NotetakeCore

@Test func shortLabelTable() {
    #expect(LocationLabel.short(inputName: "system", platform: .mac, source: .system) == "system")
    #expect(LocationLabel.short(inputName: "Apple Watch", platform: .watchos, source: .watch) == "Watch")
    #expect(LocationLabel.short(inputName: "iPhone マイク", platform: .ios, source: .mic) == "iPhone")
    #expect(LocationLabel.short(inputName: "ゆふAirPods Pro 3", platform: .mac, source: .mic) == "AirPods")
    #expect(LocationLabel.short(inputName: "MacBook Airのマイク", platform: .mac, source: .mic) == "Mac")
}

@Test func clockPositionRoundsToNearestHour() {
    #expect(LocationLabel.clock(azimuthDeg: 0) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 14) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 16) == "1時")
    #expect(LocationLabel.clock(azimuthDeg: 57.3) == "2時")
    #expect(LocationLabel.clock(azimuthDeg: 270) == "9時")
    #expect(LocationLabel.clock(azimuthDeg: 345) == "12時")
    #expect(LocationLabel.clock(azimuthDeg: 359.9) == "12時")
}

@Test func textCombinesLabelAndClock() {
    let d = Direction(azimuthDeg: 57.3, confidence: 0.8)
    #expect(LocationLabel.text(inputName: "iPhone マイク", platform: .ios, source: .mic, direction: d) == "iPhone 2時")
    #expect(LocationLabel.text(inputName: "MacBook Airのマイク", platform: .mac, source: .mic, direction: nil) == "Mac")
}
