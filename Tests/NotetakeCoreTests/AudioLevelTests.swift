import Foundation
import Testing
import AVFoundation
@testable import NotetakeCore

@Test func silenceIsMinus120() {
    #expect(AudioLevel.dbfs([Float](repeating: 0, count: 100)) == -120)
}

@Test func fullScaleSineIsAboutMinus3() {
    let count = 1000
    let samples: [Float] = (0..<count).map { i in
        Float(sin(2.0 * Double.pi * Double(i) / Double(count)))
    }
    let dbfs = AudioLevel.dbfs(samples)
    #expect(abs(dbfs - (-3.01)) < 0.05)
}

@Test func halfConstantIsAboutMinus6() {
    let samples = [Float](repeating: 0.5, count: 1000)
    let dbfs = AudioLevel.dbfs(samples)
    #expect(abs(dbfs - (-6.02)) < 0.05)
}
