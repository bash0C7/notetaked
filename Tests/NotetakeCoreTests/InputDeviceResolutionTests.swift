import Testing
@testable import NotetakeCore

@Test func resolvedUIDReturnsPinnedWhenAvailable() {
    let resolved = InputDeviceResolution.resolvedUID(
        pinnedUID: "AirPods-UID", availableUIDs: ["AirPods-UID", "BuiltInMicrophoneDevice"])
    #expect(resolved == "AirPods-UID")
}

@Test func resolvedUIDFallsBackToDefaultWhenPinnedUnavailable() {
    let resolved = InputDeviceResolution.resolvedUID(
        pinnedUID: "AirPods-UID", availableUIDs: ["BuiltInMicrophoneDevice"])
    #expect(resolved == nil)
}

@Test func resolvedUIDFallsBackToDefaultWhenNoPin() {
    let resolved = InputDeviceResolution.resolvedUID(
        pinnedUID: nil, availableUIDs: ["BuiltInMicrophoneDevice"])
    #expect(resolved == nil)
}

@Test func resolvedUIDFallsBackToDefaultWhenNoDevicesAvailable() {
    let resolved = InputDeviceResolution.resolvedUID(pinnedUID: "AirPods-UID", availableUIDs: [])
    #expect(resolved == nil)
}
