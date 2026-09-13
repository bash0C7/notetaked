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
            guard let format, frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
            guard status == noErr else { return }
            continuation.yield(CapturedBuffer(buffer: pcm))
        }
    }

    private var session: AVCaptureSession?
    private var delegate: SampleDelegate?
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.capture")
    private var transcriber: Transcriber?
    /// 取り込みformat → Transcriber input format（非FOA時）、または W ch のmono float → Transcriber input format（FOA時）
    private var converter: AudioConverter?
    /// 取り込みformat → 4ch Float32 非interleaved（FOA時のみ）
    private var foaConverter: AudioConverter?
    private var estimator = DirectionEstimator()
    private var input = InputDevice(name: "iPhone", uid: "", spatial: false)
    private var originMS: Int64 = 0
    private var clock: SampleClock?
    private var sampleTime: AVAudioFramePosition = 0
    private var lastLevelDBFS: Double = -120

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

        let origin = Date()
        originMS = Int64((origin.timeIntervalSince1970 * 1000).rounded())
        let transcriber = try await Transcriber(locale: locale, origin: origin)
        self.transcriber = transcriber
        self.clock = SampleClock(originMS: originMS, sampleRate: transcriber.inputFormat.sampleRate)
        self.converter = nil
        self.foaConverter = nil
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

        self.session = session
        self.delegate = delegate

        feedTask = Task {
            for await captured in bufferStream {
                await self.ingest(captured.buffer)
            }
        }

        forwardTask = Task {
            for await piece in pieces where piece.isFinal {
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
        self.foaConverter = nil

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
            guard let foa = try? foaBuffer(from: buffer), let data = foa.floatChannelData else { return }
            let count = Int(foa.frameLength)
            let w = Array(UnsafeBufferPointer(start: data[0], count: count))
            let y = Array(UnsafeBufferPointer(start: data[1], count: count))
            let x = Array(UnsafeBufferPointer(start: data[3], count: count))
            foaChannels = (w, y, x)
            guard let mono = Self.monoBuffer(samples: w, sampleRate: foa.format.sampleRate) else { return }
            monoSource = mono
        } else {
            monoSource = buffer
        }

        if converter == nil {
            converter = try? AudioConverter(from: monoSource.format, to: transcriber.inputFormat)
        }
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
        await transcriber.feed(converted, at: sampleTime)
        sampleTime += convertedFrames
    }

    /// 取り込みbufferを4ch Float32 非interleavedへ（初回にconverterを作る）
    private func foaBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if foaConverter == nil {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 4, interleaved: false)
            else { throw RecorderError.microphoneUnavailable }
            foaConverter = try AudioConverter(from: buffer.format, to: target)
        }
        return try foaConverter!.convert(buffer)
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
