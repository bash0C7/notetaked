import Foundation
import Testing
@testable import NotetakeCore

/// SN3D正規化のFOA平面波: W = s, X = s·cosθ, Y = s·sinθ（θは数学座標、前=+X、左=+Y、反時計回り）
private func planeWave(thetaDeg: Double, frames: Int = 480, seed: UInt64 = 1) -> (w: [Float], y: [Float], x: [Float]) {
    var state = seed
    func next() -> Float {   // 決定論的な疑似乱数 [-1, 1)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    }
    let theta = thetaDeg * .pi / 180
    var w: [Float] = [], y: [Float] = [], x: [Float] = []
    for _ in 0..<frames {
        let s = next()
        w.append(s); x.append(s * Float(cos(theta))); y.append(s * Float(sin(theta)))
    }
    return (w, y, x)
}

@Test func frontSourceIsZeroDegrees() {
    let p = planeWave(thetaDeg: 0)
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg) < 2 || abs(e.azimuthDeg - 360) < 2)
    #expect(e.confidence > 0.95)
}

@Test func rightSourceIsNinetyDegreesClockwise() {
    // 右 = 数学座標で -90°（Yは左が正）→ 時計回り表記で 90°
    let p = planeWave(thetaDeg: -90)
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 90) < 2)
}

@Test func leftFrontSourceMapsToClockwise() {
    let p = planeWave(thetaDeg: 60)   // 左前 → 時計回りで 300°
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 300) < 2)
}

@Test func backSourceIsOneEightyDegrees() {
    let p = planeWave(thetaDeg: 180)   // 後ろ → 時計回りで180°
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 180) < 2)
}

@Test func leftSourceIsTwoSeventyDegreesClockwise() {
    let p = planeWave(thetaDeg: 90)   // 左 = 数学座標で90°（Yは左が正）→ 時計回り表記で270°
    let e = DirectionEstimator.frameEstimate(w: p.w, y: p.y, x: p.x)!
    #expect(abs(e.azimuthDeg - 270) < 2)
}

@Test func diffuseNoiseHasLowConfidence() {
    let a = planeWave(thetaDeg: 0, seed: 1), b = planeWave(thetaDeg: 0, seed: 2), c = planeWave(thetaDeg: 0, seed: 3)
    let e = DirectionEstimator.frameEstimate(w: a.w, y: b.w, x: c.w)!   // 各chが独立ノイズ
    #expect(e.confidence < 0.3)
}

@Test func silenceReturnsNil() {
    let z = [Float](repeating: 0, count: 100)
    #expect(DirectionEstimator.frameEstimate(w: z, y: z, x: z) == nil)
}

@Test func segmentDirectionIsCircularMeanOfFramesInRange() {
    var est = DirectionEstimator()
    let a = planeWave(thetaDeg: 1)      // 時計回り 359°
    let b = planeWave(thetaDeg: -1)     // 時計回り 1°
    est.add(w: a.w, y: a.y, x: a.x, startMS: 0, endMS: 100)
    est.add(w: b.w, y: b.y, x: b.x, startMS: 100, endMS: 200)
    let far = planeWave(thetaDeg: -90)  // 範囲外のフレーム
    est.add(w: far.w, y: far.y, x: far.x, startMS: 5000, endMS: 5100)
    let d = est.direction(from: 0, to: 200)!
    #expect(d.azimuthDeg < 2 || d.azimuthDeg > 358)
    #expect(d.confidence > 0.95)
}

@Test func lowConfidenceFramesAreIgnoredAndNoFramesGivesNil() {
    var est = DirectionEstimator()
    let a = planeWave(thetaDeg: 0, seed: 1), b = planeWave(thetaDeg: 0, seed: 2), c = planeWave(thetaDeg: 0, seed: 3)
    est.add(w: a.w, y: b.w, x: c.w, startMS: 0, endMS: 100)   // 拡散音 → 捨てられる
    #expect(est.direction(from: 0, to: 100) == nil)
}

@Test func azimuthOffsetIsApplied() {
    var est = DirectionEstimator(azimuthOffsetDeg: 90)
    let p = planeWave(thetaDeg: 0)
    est.add(w: p.w, y: p.y, x: p.x, startMS: 0, endMS: 100)
    #expect(abs(est.direction(from: 0, to: 100)!.azimuthDeg - 90) < 2)
}

@Test func framesBeforeQueriedRangeArePruned() {
    var est = DirectionEstimator()
    let p = planeWave(thetaDeg: 0)
    est.add(w: p.w, y: p.y, x: p.x, startMS: 0, endMS: 100)
    _ = est.direction(from: 200, to: 300)
    #expect(est.direction(from: 0, to: 100) == nil)
}
