import Foundation
import Testing
@testable import NotetakeCore

@Test func sampleComputesOffsetAndRTT() {
    // t0=1000(local送信) t1=1050(remote受信) t2=1060(remote送信) t3=1120(local受信)
    let sample = ClockOffset.sample(t0: 1_000, t1: 1_050, t2: 1_060, t3: 1_120)
    #expect(sample.offsetMS == -5)
    #expect(sample.rttMS == 110)
}

@Test func sampleWithNegativeOffset() {
    // remoteが大きく遅れているケース
    let sample = ClockOffset.sample(t0: 0, t1: -100, t2: -90, t3: 100)
    #expect(sample.offsetMS == -145)
    #expect(sample.rttMS == 90)
}

@Test func sampleWithPositiveOffset() {
    // remoteがlocalより進んでいるケース
    let sample = ClockOffset.sample(t0: 0, t1: 200, t2: 210, t3: 100)
    #expect(sample.offsetMS == 155)
    #expect(sample.rttMS == 90)
}

@Test func bestPicksMinimumRTT() {
    let samples = [
        ClockOffsetSample(offsetMS: 1, rttMS: 50),
        ClockOffsetSample(offsetMS: 2, rttMS: 10),
        ClockOffsetSample(offsetMS: 3, rttMS: 30),
    ]
    #expect(ClockOffset.best(samples) == ClockOffsetSample(offsetMS: 2, rttMS: 10))
}

@Test func bestTieBreaksToFirst() {
    let samples = [
        ClockOffsetSample(offsetMS: 1, rttMS: 10),
        ClockOffsetSample(offsetMS: 2, rttMS: 10),
    ]
    #expect(ClockOffset.best(samples) == ClockOffsetSample(offsetMS: 1, rttMS: 10))
}

@Test func bestOfEmptyIsNil() {
    #expect(ClockOffset.best([]) == nil)
}

@Test func segmentOffsetMSNegatesRemoteOffset() {
    #expect(ClockOffset.segmentOffsetMS(fromRemoteOffset: 50) == -50)
    #expect(ClockOffset.segmentOffsetMS(fromRemoteOffset: -30) == 30)
    #expect(ClockOffset.segmentOffsetMS(fromRemoteOffset: 0) == 0)
}
