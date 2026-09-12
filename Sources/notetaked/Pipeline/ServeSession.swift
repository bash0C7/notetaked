#if canImport(Speech)
import Foundation
import NotetakeCore

/// serve daemonの収録状態（store / reconciler / seq / 起動中のCaptureStream）を保持し、
/// stdinのCommandとcapture eventが競合しないよう1つのactorへ直列化する
@available(macOS 26, iOS 26, *)
actor ServeSession {
    enum SourceOption: String {
        case mic, system, both

        var sources: [(source: Source, owner: (_ configuredOwner: String) -> String)] {
            switch self {
            case .mic:
                return [(.mic, { $0 })]
            case .system:
                return [(.system, { _ in "リモート" })]
            case .both:
                return [(.mic, { $0 }), (.system, { _ in "リモート" })]
            }
        }
    }

    private struct RunningStream {
        let source: Source
        let owner: String
        let stream: CaptureStream
        let consumer: Task<Void, Never>
    }

    private let outputDirectory: URL
    private let owner: String
    private let sourceOption: SourceOption
    private let locale: Locale
    private let control: StdioControl
    private let device: DeviceIdentity

    private var store: SessionStore?
    private var reconciler = Reconciler()
    private var seq = 0
    private var streams: [RunningStream] = []
    private var recording = false

    init(
        outputDirectory: URL, owner: String, sourceOption: SourceOption, locale: Locale,
        control: StdioControl, device: DeviceIdentity
    ) {
        self.outputDirectory = outputDirectory
        self.owner = owner
        self.sourceOption = sourceOption
        self.locale = locale
        self.control = control
        self.device = device
    }

    func handle(_ command: Command) async {
        switch command {
        case .start:
            await start()
        case .stop:
            await stop()
        case .renameSpeaker(let id, let name):
            await renameSpeaker(id: id, name: name)
        case .quit:
            await quit()
        }
    }

    // MARK: - start

    private func start() async {
        guard !recording else {
            await control.send(.error("already recording"))
            return
        }

        let startDate = Date()
        let store = SessionStore(directory: outputDirectory, start: startDate)
        do {
            try await store.append(
                .session(
                    SessionRecord(
                        id: store.prefix,
                        started: Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
                        owner: owner)))
            try await store.append(
                .device(
                    DeviceRecord(
                        device: device.id, deviceName: device.name, owner: owner,
                        platform: .mac, offsetMS: 0)))
        } catch {
            await store.close()
            await control.send(.error("failed to start session: \(error)"))
            return
        }

        var started: [RunningStream] = []
        var startError: Error?

        for (source, ownerFor) in sourceOption.sources {
            do {
                let capture: any AudioCapture
                switch source {
                case .mic:
                    capture = MicCapture()
                case .system:
                    capture = try SystemAudioCapture()
                case .watch:
                    throw CaptureStreamError.sourceNotImplemented(source)
                }
                let captureStream = try await CaptureStream(
                    source: source, capture: capture, locale: locale)
                let events = try await captureStream.start()
                let streamOwner = ownerFor(owner)
                let consumer = Task { [weak self] in
                    for await event in events {
                        await self?.handle(streamEvent: event, source: source, owner: streamOwner)
                    }
                }
                started.append(
                    RunningStream(
                        source: source, owner: streamOwner, stream: captureStream,
                        consumer: consumer))
            } catch {
                startError = error
                break
            }
        }

        if let startError {
            for running in started {
                try? await running.stream.stop()
                await running.consumer.value
            }
            await store.close()
            await control.send(.error("failed to start capture: \(startError)"))
            return
        }

        self.store = store
        self.reconciler = Reconciler()
        self.seq = 0
        self.streams = started
        self.recording = true

        await control.send(
            .status(
                StatusEvent(
                    recording: true, prefix: store.prefix,
                    sources: started.map(\.source), outputDirectory: outputDirectory.path)))
    }

    // MARK: - stream events

    private func handle(streamEvent: StreamEvent, source: Source, owner: String) async {
        switch streamEvent {
        case .volatile(let text):
            await control.send(.volatile(source: source, text: text))
        case .final(let piece, let levelDBFS):
            await handleFinal(piece, levelDBFS: levelDBFS, source: source, owner: owner)
        }
    }

    private func handleFinal(
        _ piece: TranscriptPiece, levelDBFS: Double, source: Source, owner: String
    ) async {
        guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let store else { return }

        seq += 1
        let receivedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let segment = Segment(
            id: UUID(),
            session: store.prefix,
            seq: seq,
            device: device.id,
            deviceName: device.name,
            owner: owner,
            platform: .mac,
            source: source,
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: levelDBFS,
            clockOffsetMS: 0,
            receivedAt: receivedAt)

        do {
            try await store.append(.segment(segment))
        } catch {
            await control.send(.error("failed to append segment: \(error)"))
            return
        }

        for utterance in reconciler.apply(.segment(segment)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - rename_speaker

    private func renameSpeaker(id: String, name: String) async {
        guard recording, let store else {
            await control.send(.error("not recording"))
            return
        }

        let rename = SpeakerNameRecord(speaker: id, name: name)
        do {
            try await store.append(.speakerName(rename))
        } catch {
            await control.send(.error("failed to rename speaker: \(error)"))
            return
        }

        for utterance in reconciler.apply(.speakerName(rename)) {
            await control.send(.utterance(utterance))
        }
    }

    // MARK: - stop

    private func stop() async {
        guard recording, let store else {
            await control.send(.error("not recording"))
            return
        }

        for running in streams {
            do {
                try await running.stream.stop()
            } catch {
                await control.send(.error("failed to stop capture: \(error)"))
                // CaptureStream.stop()はfailure時もevent streamをfinishさせるが、
                // 万一終わらなかった場合にconsumerのfor-awaitが無限にwedgeしないよう保険で
                // cancelしてからawaitする
                running.consumer.cancel()
            }
            await running.consumer.value
        }
        streams = []

        let markdown = TranscriptRenderer.markdown(reconciler.utterances, timeZone: .current)
        do {
            try await store.writeFinal(markdown)
        } catch {
            await control.send(.error("failed to write final: \(error)"))
        }
        await store.close()

        self.store = nil
        recording = false

        await control.send(
            .status(
                StatusEvent(
                    recording: false, prefix: nil, sources: [],
                    outputDirectory: outputDirectory.path)))
    }

    // MARK: - quit

    private func quit() async {
        if recording {
            await stop()
        }
    }
}
#endif
