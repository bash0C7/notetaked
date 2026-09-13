import AVFoundation
import Foundation
import NotetakeCore

enum RecorderError: Error {
    case alreadyRunning
    case microphoneUnavailable
}

/// マイク入力（AVCaptureSession）→ AudioConverter → Transcriber(SpeechAnalyzer) をつなぐiPhone側のpipeline。
/// 空間収録（FOA）対応機材ではW chをTranscriberへ、4chをDirectionEstimatorへ流し、final pieceごとに方位を付ける
@available(iOS 26, *)
actor Recorder {
    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// AVCaptureAudioDataOutputのdelegate。CMSampleBufferをAVAudioPCMBufferへコピーしてactorへ渡す
    private final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        let continuation: AsyncStream<CapturedBuffer>.Continuation
        let channelLayout: AVAudioChannelLayout?
        var bufferCount = 0

        init(continuation: AsyncStream<CapturedBuffer>.Continuation, channelLayout: AVAudioChannelLayout?) {
            self.continuation = continuation
            self.channelLayout = channelLayout
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else { return }
            let format: AVAudioFormat?
            if let channelLayout, asbd.pointee.mChannelsPerFrame == channelLayout.channelCount {
                format = AVAudioFormat(streamDescription: asbd, channelLayout: channelLayout)
            } else {
                format = AVAudioFormat(streamDescription: asbd)
            }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            if bufferCount == 0 { FileHandle.standardError.write(Data("recorder: first buffer ch=\(asbd.pointee.mChannelsPerFrame) rate=\(asbd.pointee.mSampleRate) frames=\(frames) flags=\(asbd.pointee.mFormatFlags) bits=\(asbd.pointee.mBitsPerChannel)\n".utf8)) }
            bufferCount += 1
            if format == nil { FileHandle.standardError.write(Data("recorder: AVAudioFormat nil\n".utf8)) }
            guard let format, frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard status == noErr else { FileHandle.standardError.write(Data("recorder: copy status=\(status)\n".utf8)); return }
            continuation.yield(CapturedBuffer(buffer: pcm))
        }
    }

    private var session: AVCaptureSession?
    private var delegate: SampleDelegate?
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.capture")
    private var transcriber: Transcriber?
    /// 取り込みformat → Transcriber input format（非FOA時）、または W ch のmono float → Transcriber input format（FOA時）
    private var converter: AudioConverter?
    private var estimator = DirectionEstimator()
    private var input = InputDevice(name: "iPhone", uid: "", spatial: false)
    private var originMS: Int64 = 0
    private var clock: SampleClock?
    private var sampleTime: AVAudioFramePosition = 0
    private var lastLevelDBFS: Double = -120
    private var ingestCount = 0
    private var axisE: Float = 0, axis1: Float = 0, axis2: Float = 0, axis3: Float = 0
    private func i1Str(_ v: Float) -> String { String(format: "%.3f", v) }

    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var forwardTask: Task<Void, Never>?

    func currentInput() -> InputDevice { input }

    func start(
        locale: Locale,
        onPiece: @escaping @Sendable (TranscriptPiece, Double, Direction?) -> Void
    ) async throws {
        guard session == nil else { throw RecorderError.alreadyRunning }
        guard let microphone = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
            throw RecorderError.microphoneUnavailable
        }
        let deviceInput = try AVCaptureDeviceInput(device: microphone)
        let spatial = deviceInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
        input = InputDevice(name: microphone.localizedName, uid: microphone.uniqueID, spatial: spatial)
        FileHandle.standardError.write(Data("recorder: input=\(microphone.localizedName) spatial=\(spatial)\n".utf8))

        let origin = Date()
        originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        self.transcriber = transcriber
        self.clock = SampleClock(originMS: originMS, sampleRate: transcriber.inputFormat.sampleRate)
        self.converter = nil
        self.estimator = DirectionEstimator()
        self.sampleTime = 0
        self.lastLevelDBFS = -120

        let pieces = try await transcriber.start()

        let (bufferStream, bufferContinuation) = AsyncStream<CapturedBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation

        let foaLayout = spatial ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_HOA_ACN_SN3D | 4) : nil
        let delegate = SampleDelegate(continuation: bufferContinuation, channelLayout: foaLayout)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: queue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            bufferContinuation.finish()
            self.bufferContinuation = nil
            self.transcriber = nil
            try? await transcriber.finish()
            throw RecorderError.microphoneUnavailable
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        if spatial {
            deviceInput.multichannelAudioMode = .firstOrderAmbisonics
            output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        }
        session.commitConfiguration()
        session.startRunning()
        FileHandle.standardError.write(Data("recorder: session running=\(session.isRunning) inputs=\(session.inputs.count) outputs=\(session.outputs.count)\n".utf8))

        self.session = session
        self.delegate = delegate

        feedTask = Task {
            for await captured in bufferStream {
                await self.ingest(captured.buffer)
            }
        }

        forwardTask = Task {
            for await piece in pieces where piece.isFinal {
                FileHandle.standardError.write(Data("recorder: final piece \(piece.text.prefix(20))\n".utf8))
                let (level, direction) = self.finish(piece: piece)
                onPiece(piece, level, direction)
            }
        }
    }

    func stop() async throws {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        self.delegate = nil

        bufferContinuation?.finish()
        bufferContinuation = nil
        await feedTask?.value
        feedTask = nil

        let transcriber = self.transcriber
        self.transcriber = nil
        self.clock = nil
        self.converter = nil

        do {
            try await transcriber?.finish()
        } catch {
            await forwardTask?.value
            forwardTask = nil
            throw error
        }
        await forwardTask?.value
        forwardTask = nil
    }

    private func ingest(_ buffer: sending AVAudioPCMBuffer) async {
        guard let transcriber, let clock else { return }

        let monoSource: AVAudioPCMBuffer
        var foaChannels: (w: [Float], y: [Float], x: [Float])?
        if input.spatial, buffer.format.channelCount == 4 {
            guard let channels = Self.foaChannels(from: buffer) else {
                if ingestCount % 200 == 0 {
                    FileHandle.standardError.write(Data("recorder: unsupported FOA format \(buffer.format)\n".utf8))
                }
                ingestCount += 1
                return
            }
            // 診断: 軸の対応を実機で割り出すため、各chとWの相関（音響インテンシティ成分）を50 bufferごとに出す
            if let data = buffer.floatChannelData, buffer.format.isInterleaved {
                let p = data[0]
                var e: Float = 0, i1: Float = 0, i2: Float = 0, i3: Float = 0
                for i in 0..<Int(buffer.frameLength) {
                    let w = p[i * 4]
                    e += w * w; i1 += w * p[i * 4 + 1]; i2 += w * p[i * 4 + 2]; i3 += w * p[i * 4 + 3]
                }
                axisE += e; axis1 += i1; axis2 += i2; axis3 += i3
                if ingestCount % 50 == 49 {
                    let n = max(axisE, 1e-9)
                    FileHandle.standardError.write(Data("recorder: axes ch1=\(i1Str(axis1 / n)) ch2=\(i1Str(axis2 / n)) ch3=\(i1Str(axis3 / n)) E=\(i1Str(axisE))\n".utf8))
                    axisE = 0; axis1 = 0; axis2 = 0; axis3 = 0
                }
            }
            foaChannels = channels
            guard let mono = Self.monoBuffer(samples: channels.w, sampleRate: buffer.format.sampleRate) else { return }
            monoSource = mono
        } else {
            monoSource = buffer
        }

        if converter == nil {
            converter = try? AudioConverter(from: monoSource.format, to: transcriber.inputFormat)
        }
        if converter == nil { FileHandle.standardError.write(Data("recorder: converter nil from=\(monoSource.format) to=\(transcriber.inputFormat)\n".utf8)) }
        guard let converter, let converted = try? converter.convert(monoSource) else { return }
        let convertedFrames = AVAudioFramePosition(converted.frameLength)

        // 時刻はTranscriberと同じ変換後サンプル数の時計で作る（親spec「時刻基準」）
        if let foaChannels {
            estimator.add(
                w: foaChannels.w, y: foaChannels.y, x: foaChannels.x,
                startMS: clock.ms(atFrame: sampleTime),
                endMS: clock.ms(atFrame: sampleTime + convertedFrames))
        }
        lastLevelDBFS = AudioLevel.dbfs(converted)
        if ingestCount % 200 == 0 { FileHandle.standardError.write(Data("recorder: fed frames=\(convertedFrames) dbfs=\(lastLevelDBFS) sampleTime=\(sampleTime)\n".utf8)) }
        ingestCount += 1
        await transcriber.feed(converted, at: sampleTime)
        sampleTime += convertedFrames
    }

    /// FOA 4ch buffer（ACN順: 0=W, 1=Y, 2=Z, 3=X）からW / Y / Xを取り出す。
    /// Float32のinterleaved / non-interleavedの両方を受け付け、AVAudioConverterは使わない
    /// （4chのtarget formatはchannel layout無しでは作れず、layout付きでも並びが保たれる保証が無いため）
    private static func foaChannels(from buffer: AVAudioPCMBuffer) -> (w: [Float], y: [Float], x: [Float])? {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            let interleaved = data[0]
            var w = [Float](repeating: 0, count: count)
            var y = w
            var x = w
            for i in 0..<count {
                w[i] = interleaved[i * 4]
                y[i] = interleaved[i * 4 + 1]
                x[i] = interleaved[i * 4 + 3]
            }
            return (w, y, x)
        }
        return (
            Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count)),
            Array(UnsafeBufferPointer(start: data[3], count: count)))
    }

    private static func monoBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    private func finish(piece: TranscriptPiece) -> (Double, Direction?) {
        let direction = input.spatial ? estimator.direction(from: piece.startMS, to: piece.endMS) : nil
        return (lastLevelDBFS, direction)
    }
}
