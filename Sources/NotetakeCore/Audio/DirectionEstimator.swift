import Foundation

/// FOA（ACN順 / SN3D: ch0=W, ch1=Y, ch2=Z, ch3=X）から水平方位を推定する純粋計算。
/// フレームごとの推定を貯め、seg の時間範囲で信頼度重みの円平均を取る
public struct DirectionEstimator: Sendable {
    public struct Frame: Sendable, Equatable {
        public var azimuthDeg: Double
        public var confidence: Double
        public var startMS: Int64
        public var endMS: Int64
    }

    /// FOA座標系と機材の「上」がずれていた場合の補正（実機で決める）
    public var azimuthOffsetDeg: Double
    /// これ未満の信頼度のフレームは捨てる
    public var minimumFrameConfidence: Double
    private var frames: [Frame] = []

    public init(azimuthOffsetDeg: Double = 0, minimumFrameConfidence: Double = 0.2) {
        self.azimuthOffsetDeg = azimuthOffsetDeg
        self.minimumFrameConfidence = minimumFrameConfidence
    }

    /// 1フレームの音響インテンシティから方位（時計回り・上基準、補正なし）と信頼度を求める。
    /// 無音（Σw² == 0）ならnil
    public static func frameEstimate(w: [Float], y: [Float], x: [Float]) -> (azimuthDeg: Double, confidence: Double)? {
        var ix = 0.0, iy = 0.0, energy = 0.0
        for i in 0..<min(w.count, y.count, x.count) {
            let wi = Double(w[i])
            ix += wi * Double(x[i])
            iy += wi * Double(y[i])
            energy += wi * wi
        }
        guard energy > 0 else { return nil }
        let thetaDeg = atan2(iy, ix) * 180 / .pi          // 数学座標（反時計回り、前=0）
        let confidence = min(1, (ix * ix + iy * iy).squareRoot() / energy)
        return (Self.normalize(360 - thetaDeg), confidence)
    }

    public mutating func add(w: [Float], y: [Float], x: [Float], startMS: Int64, endMS: Int64) {
        guard let estimate = Self.frameEstimate(w: w, y: y, x: x),
              estimate.confidence >= minimumFrameConfidence
        else { return }
        frames.append(Frame(azimuthDeg: estimate.azimuthDeg, confidence: estimate.confidence,
                            startMS: startMS, endMS: endMS))
    }

    /// [startMS, endMS] と重なるフレームの信頼度重み付き円平均。startMSより前に終わったフレームは捨てる
    public mutating func direction(from startMS: Int64, to endMS: Int64) -> Direction? {
        frames.removeAll { $0.endMS < startMS }
        var sumX = 0.0, sumY = 0.0, weight = 0.0
        for frame in frames where frame.startMS <= endMS && frame.endMS >= startMS {
            let rad = frame.azimuthDeg * .pi / 180
            sumX += frame.confidence * cos(rad)
            sumY += frame.confidence * sin(rad)
            weight += frame.confidence
        }
        guard weight > 0 else { return nil }
        let meanDeg = atan2(sumY, sumX) * 180 / .pi
        let resultant = (sumX * sumX + sumY * sumY).squareRoot() / weight
        return Direction(azimuthDeg: Self.normalize(meanDeg + azimuthOffsetDeg), confidence: resultant)
    }

    private static func normalize(_ deg: Double) -> Double {
        var value = deg.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value == 360 ? 0 : value
    }
}
