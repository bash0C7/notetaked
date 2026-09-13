import Foundation
import Testing

@testable import NotetakeCore

@Test func firstEmbeddingGetsG1() {
    var registry = SpeakerRegistry()
    let id = registry.assign(streamKey: "mic", localID: "0", embedding: [1, 0, 0, 0])

    #expect(id == "g1")
    #expect(registry.profiles.count == 1)
    #expect(registry.profiles[0].id == "g1")
    #expect(registry.profiles[0].count == 1)
}

@Test func similarEmbeddingReusesIDAndUpdatesCentroidCount() {
    var registry = SpeakerRegistry()
    let firstID = registry.assign(streamKey: "mic", localID: "0", embedding: [1, 0, 0, 0])
    // cosine([1,0,0,0], [0.9,0.1,0,0]) > 0.7
    let secondID = registry.assign(streamKey: "mic", localID: "1", embedding: [0.9, 0.1, 0, 0])

    #expect(secondID == firstID)
    #expect(registry.profiles.count == 1)
    #expect(registry.profiles[0].count == 2)
}

@Test func orthogonalEmbeddingGetsNewID() {
    var registry = SpeakerRegistry()
    _ = registry.assign(streamKey: "mic", localID: "0", embedding: [1, 0, 0, 0])
    let id = registry.assign(streamKey: "mic", localID: "1", embedding: [0, 1, 0, 0])

    #expect(id == "g2")
    #expect(registry.profiles.count == 2)
}

@Test func sameStreamAndLocalIDSticksDespiteDissimilarEmbedding() {
    var registry = SpeakerRegistry()
    let firstID = registry.assign(streamKey: "mic", localID: "0", embedding: [1, 0, 0, 0])
    // Same (streamKey, localID): must reuse firstID even though this embedding is orthogonal.
    let secondID = registry.assign(streamKey: "mic", localID: "0", embedding: [0, 1, 0, 0])

    #expect(secondID == firstID)
    #expect(registry.profiles.count == 1)
    #expect(registry.profiles[0].count == 2)
}

@Test func seededNamedProfileMatchesPreservesNameAndContinuesNumbering() {
    let seeded = SpeakerProfile(id: "g3", name: "田中", centroid: [1, 0, 0, 0], count: 5)
    var registry = SpeakerRegistry(profiles: [seeded])

    let matchedID = registry.assign(streamKey: "mic", localID: "0", embedding: [0.95, 0.05, 0, 0])
    #expect(matchedID == "g3")
    #expect(registry.name(for: "g3") == "田中")
    #expect(registry.profiles.first(where: { $0.id == "g3" })?.count == 6)

    let newID = registry.assign(streamKey: "mic", localID: "1", embedding: [0, 0, 1, 0])
    #expect(newID == "g4")
}

@Test func setNameAndNamedProfiles() {
    var registry = SpeakerRegistry()
    let id = registry.assign(streamKey: "mic", localID: "0", embedding: [1, 0, 0, 0])
    #expect(registry.namedProfiles.isEmpty)
    #expect(registry.name(for: id) == nil)

    registry.setName("Alice", for: id)

    #expect(registry.name(for: id) == "Alice")
    #expect(registry.namedProfiles.map(\.id) == [id])
}

@Test func cosineSimilarityZeroVectorAndLengthMismatch() {
    #expect(SpeakerRegistry.cosineSimilarity([0, 0, 0, 0], [1, 0, 0, 0]) == 0)
    #expect(SpeakerRegistry.cosineSimilarity([1, 0, 0, 0], [0, 0, 0, 0]) == 0)
    #expect(SpeakerRegistry.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
    #expect(SpeakerRegistry.cosineSimilarity([], []) == 0)
}

@Test func speakerProfileJSONRoundTrip() throws {
    let profile = SpeakerProfile(id: "g1", name: "田中", centroid: [0.1, 0.2, 0.3, 0.4], count: 3)
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(SpeakerProfile.self, from: data)

    #expect(decoded == profile)
}

@Test func speakerProfileJSONRoundTripWithNilName() throws {
    let profile = SpeakerProfile(id: "g2", centroid: [0, 1, 0, 0], count: 1)
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(SpeakerProfile.self, from: data)

    #expect(decoded == profile)
    #expect(decoded.name == nil)
}
