import AVFoundation

public enum AudioLevel {
    /// RMSをdBFSに（20*log10(rms)）。rmsが0なら-120
    public static func dbfs(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sumSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }

    /// float32 / int16 両対応、複数chはchannel 0
    public static func dbfs(_ buffer: AVAudioPCMBuffer) -> Double {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -120 }

        if let floatData = buffer.floatChannelData {
            let channel = floatData[0]
            var samples = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength { samples[i] = channel[i] }
            return dbfs(samples)
        }

        if let int16Data = buffer.int16ChannelData {
            let channel = int16Data[0]
            var samples = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength { samples[i] = Float(channel[i]) / Float(Int16.max) }
            return dbfs(samples)
        }

        return -120
    }
}
