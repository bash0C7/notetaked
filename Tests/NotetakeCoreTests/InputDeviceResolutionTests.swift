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

private let builtIn = InputCandidate(uid: "BuiltInMicrophoneDevice", transport: .builtIn)
private let airPods = InputCandidate(uid: "AirPods-UID", transport: .other)
private let iPhone = InputCandidate(uid: "iPhone-UID", transport: .continuity)

@Test func fallbackUIDKeepsOSDefaultWhenNotContinuity() {
    let uid = InputDeviceResolution.fallbackUID(
        osDefaultUID: "AirPods-UID", candidates: [builtIn, airPods, iPhone])
    #expect(uid == "AirPods-UID")
}

@Test func fallbackUIDPrefersBuiltInWhenOSDefaultIsContinuity() {
    let uid = InputDeviceResolution.fallbackUID(
        osDefaultUID: "iPhone-UID", candidates: [iPhone, builtIn])
    #expect(uid == "BuiltInMicrophoneDevice")
}

@Test func fallbackUIDIsNilWhenOnlyContinuityRemains() {
    let uid = InputDeviceResolution.fallbackUID(osDefaultUID: "iPhone-UID", candidates: [iPhone])
    #expect(uid == nil)
}

@Test func fallbackUIDIsNilWhenNoOSDefault() {
    let uid = InputDeviceResolution.fallbackUID(osDefaultUID: nil, candidates: [])
    #expect(uid == nil)
}

@Test func sanitizedPreferredUIDDropsContinuity() {
    let uid = InputDeviceResolution.sanitizedPreferredUID(
        "iPhone-UID", candidates: [builtIn, iPhone])
    #expect(uid == nil)
}

@Test func sanitizedPreferredUIDKeepsOtherAndUnknown() {
    #expect(InputDeviceResolution.sanitizedPreferredUID(
        "AirPods-UID", candidates: [builtIn, airPods]) == "AirPods-UID")
    #expect(InputDeviceResolution.sanitizedPreferredUID(
        "AirPods-UID", candidates: [builtIn]) == "AirPods-UID")
}
