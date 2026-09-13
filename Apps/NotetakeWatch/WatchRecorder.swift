import AVFoundation
import Foundation
import NotetakeCore
import WatchConnectivity

/// Watchの録音状態と、AVAudioEngine → 20秒ごとのAAC小片 → `WCSession.transferFile`の一連を管理する。
/// v1は前面のみで録音する前提（バックグラウンド録音の継続は保証しない）。
///
/// 並行性: 本体は`@MainActor`。`WCSessionDelegate`のメソッド（watchOSでは`activationDidCompleteWith`が
/// 必須、`didFinish fileTransfer:`は自前で使う）はバックグラウンドの任意スレッドから呼ばれるため、
/// 下の`extension`で`nonisolated`として実装し、`Task { @MainActor [weak self] in ... }`経由でのみ
/// 本体の状態に触れる。実際のPCM書き込みとrotation判定は`ChunkWriter`（actor）に切り出し、
/// AVAudioEngineのtap callback（real-time thread）からは`AsyncStream`へ`yield`するだけにして、
/// 1本の`Task`が順番に`await writer.append(buffer)`する（buffer到着順を保つため。tap callbackから
/// bufferごとに個別の`Task`を積むとスケジューリング順序がFIFOである保証がない）。
@MainActor
@Observable
final class WatchRecorder: NSObject {
    /// tap callback（audioスレッド）からfeedTaskへbufferを渡すための値型wrapper。
    /// `@unchecked Sendable`の根拠: tapはyield後にbufferへ触れず、受け取ったfeedTaskだけが読む（`Recorder.CapturedBuffer`と同じ）
    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private enum DefaultsKey {
        static let ownerName = "ownerName"
    }

    private static let chunkDurationSeconds: Double = 20

    private(set) var isRecording = false
    private(set) var elapsedSeconds: Int = 0
    /// 転送完了（`didFinish`のsuccess）がまだ届いていない小片の数。起動時に再送をキューした
    /// leftoverも含む。
    private(set) var pendingTransfers: Int = 0
    var lastError: String?

    /// 収録に載せる自分の名前。今はUserDefaultsのみ（`WCSession.applicationContext`経由でiPhoneから
    /// 受け取るのは将来の拡張）。
    var ownerName: String {
        didSet { UserDefaults.standard.set(ownerName, forKey: DefaultsKey.ownerName) }
    }

    private let engine = AVAudioEngine()
    private var bufferContinuation: AsyncStream<CapturedBuffer>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var writer: ChunkWriter?

    override init() {
        ownerName = UserDefaults.standard.string(forKey: DefaultsKey.ownerName) ?? "私"
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        // 前回の異常終了などで送り切れなかった小片をsidecarのmetadataから復元して再送する。
        pendingTransfers = ChunkTransfer.resendLeftovers(in: Self.chunksDirectory())
    }

    // MARK: - Recording

    func start() {
        guard !isRecording else { return }
        lastError = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            lastError = "マイクの初期化に失敗しました: \(error.localizedDescription)"
            return
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let sessionStartMS = Self.nowMS()

        let writer: ChunkWriter
        do {
            writer = try ChunkWriter(
                session: String(sessionStartMS),
                sessionStartMS: sessionStartMS,
                inputFormat: inputFormat,
                device: WatchIdentity.deviceID(),
                deviceName: WatchIdentity.deviceName,
                owner: ownerName,
                chunkDurationSeconds: Self.chunkDurationSeconds,
                chunksDirectory: Self.chunksDirectory()
            )
        } catch {
            lastError = "録音ファイルの作成に失敗しました: \(error.localizedDescription)"
            try? audioSession.setActive(false)
            return
        }
        self.writer = writer

        let (stream, continuation) = AsyncStream<CapturedBuffer>.makeStream()
        bufferContinuation = continuation
        // このclosureはreal-time audio threadから呼ばれる。`continuation`はSendableな値型で、
        // `self`やactorには触れないので、engineのtapとしてそのまま安全に使える。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            continuation.yield(CapturedBuffer(buffer: buffer))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            bufferContinuation = nil
            self.writer = nil
            Task { _ = await writer.finish() }
            lastError = "録音の開始に失敗しました: \(error.localizedDescription)"
            try? audioSession.setActive(false)
            return
        }

        feedTask = Task { @MainActor [weak self] in
            for await captured in stream {
                let outcome = await writer.append(captured.buffer)
                guard let self else { return }
                switch outcome {
                case .ok:
                    break
                case .chunkQueued:
                    self.pendingTransfers += 1
                case .writeFailed(let message):
                    self.lastError = message
                }
            }
        }

        isRecording = true
        elapsedSeconds = 0
        startElapsedTimer()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        elapsedTask?.cancel()
        elapsedTask = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil

        let writer = self.writer
        self.writer = nil
        let feedTask = self.feedTask
        self.feedTask = nil

        // feedTaskが積み残しのbufferを全部writerへ渡し終えるのを待ってから、最後の小片を
        // 閉じて転送する（そうしないと末尾の数百msが失われる）。
        Task { @MainActor [weak self] in
            await feedTask?.value
            if let queued = await writer?.finish(), queued {
                self?.pendingTransfers += 1
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func startElapsedTimer() {
        let startedAt = Date()
        elapsedTask = Task { @MainActor [weak self] in
            while let self, self.isRecording {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isRecording else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            }
        }
    }

    private static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func chunksDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("chunks", isDirectory: true)
    }
}

// MARK: - WCSessionDelegate

extension WatchRecorder: WCSessionDelegate {
    /// watchOSで必須のdelegateメソッド。バックグラウンドの任意スレッドから呼ばれるため`nonisolated`。
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.lastError = "WCSessionの有効化に失敗しました: \(error.localizedDescription)"
        }
    }

    /// `transferFile`の完了通知。成功なら小片本体とsidecarを削除し、失敗ならファイルを残して
    /// （`WCSession`が自動で再試行するが、アプリ再起動時にも`resendLeftovers`から拾えるように）
    /// `lastError`に記録するだけにとどめる。
    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let url = fileTransfer.file.fileURL
        if let error {
            Task { @MainActor [weak self] in
                self?.lastError = "小片の転送に失敗しました: \(error.localizedDescription)"
            }
            return
        }
        ChunkTransfer.cleanup(fileURL: url)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingTransfers = max(0, self.pendingTransfers - 1)
        }
    }
}

// MARK: - ChunkWriter

/// 現在の小片ファイルへPCM bufferを直列に書き込み、累積frame数が`chunkDurationSeconds`分に達したら
/// 閉じて次のファイルへrotateする。閉じた小片は`ChunkTransfer`でsidecar付きの転送キューに入れる。
/// `AVAudioFile`はcompressed(AAC)設定で開き、`commonFormat`/`interleaved`はtapのnative formatに
/// 合わせるため変換無しで書き込める（sample rateもtapのnative rateをそのまま使い、Watch側では
/// 16kHzへのresampleをしない。実際のsample rateは`WatchChunkMetadata.sampleRate`でiPhone側へ伝える）。
actor ChunkWriter {
    enum AppendOutcome: Sendable, Equatable {
        case ok
        case chunkQueued
        case writeFailed(String)
    }

    private let session: String
    private let sessionStartMS: Int64
    private let sampleRate: Double
    private let device: String
    private let deviceName: String
    private let owner: String
    private let chunkFrameLimit: AVAudioFramePosition
    private let chunksDirectory: URL
    private let fileSettings: [String: Any]
    private let commonFormat: AVAudioCommonFormat
    private let interleaved: Bool

    private var index = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentChunkStartMS: Int64
    private var framesWrittenInChunk: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0

    init(
        session: String,
        sessionStartMS: Int64,
        inputFormat: AVAudioFormat,
        device: String,
        deviceName: String,
        owner: String,
        chunkDurationSeconds: Double,
        chunksDirectory: URL
    ) throws {
        self.session = session
        self.sessionStartMS = sessionStartMS
        self.sampleRate = inputFormat.sampleRate
        self.device = device
        self.deviceName = deviceName
        self.owner = owner
        self.chunkFrameLimit = AVAudioFramePosition(
            (chunkDurationSeconds * inputFormat.sampleRate).rounded())
        self.chunksDirectory = chunksDirectory
        self.commonFormat = inputFormat.commonFormat
        self.interleaved = inputFormat.isInterleaved
        self.currentChunkStartMS = sessionStartMS
        self.fileSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 32000,
        ]
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        self.currentFile = file
        self.currentURL = url
    }

    /// bufferを現在のfileへ書き込む。rotationの閾値に達したら閉じて転送キューへ入れ、次のfileを開く。
    func append(_ buffer: sending AVAudioPCMBuffer) -> AppendOutcome {
        guard let currentFile else {
            return .writeFailed("録音ファイルが開かれていません")
        }
        do {
            try currentFile.write(from: buffer)
        } catch {
            return .writeFailed("小片の書き込みに失敗しました: \(error.localizedDescription)")
        }
        framesWrittenInChunk += AVAudioFramePosition(buffer.frameLength)
        guard framesWrittenInChunk >= chunkFrameLimit else {
            return .ok
        }

        let queued = closeAndTransferCurrentFile()
        totalFrames += framesWrittenInChunk
        framesWrittenInChunk = 0
        index += 1
        currentChunkStartMS = sessionStartMS + Int64((Double(totalFrames) / sampleRate * 1000).rounded())
        do {
            try openNextFile()
        } catch {
            return .writeFailed("次の小片ファイルの作成に失敗しました: \(error.localizedDescription)")
        }
        return queued ? .chunkQueued : .ok
    }

    /// 収録停止時。書きかけの最後の小片があれば閉じて転送する。戻り値は転送をキューしたかどうか。
    func finish() -> Bool {
        closeAndTransferCurrentFile()
    }

    /// 非asyncなactor initはnonisolatedで隔離メソッドを呼べないため、
    /// ファイルを開く処理はstaticにしてinitと`openNextFile()`の両方から使う
    private static func openFile(
        directory: URL, session: String, index: Int, settings: [String: Any],
        commonFormat: AVAudioCommonFormat, interleaved: Bool
    ) throws -> (AVAudioFile, URL) {
        let url = directory.appendingPathComponent("\(session)-\(index).m4a")
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: commonFormat, interleaved: interleaved)
        return (file, url)
    }

    private func openNextFile() throws {
        let (file, url) = try Self.openFile(
            directory: chunksDirectory, session: session, index: index, settings: fileSettings,
            commonFormat: commonFormat, interleaved: interleaved)
        currentFile = file
        currentURL = url
    }

    private func closeAndTransferCurrentFile() -> Bool {
        guard let url = currentURL else { return false }
        currentFile = nil
        currentURL = nil
        guard framesWrittenInChunk > 0 else {
            // 何も書けていない（開始直後に停止した等）空fileは転送せず捨てる。
            try? FileManager.default.removeItem(at: url)
            return false
        }
        let metadata = WatchChunkMetadata(
            session: session, index: index, startAtMS: currentChunkStartMS,
            sampleRate: sampleRate, device: device, deviceName: deviceName, owner: owner)
        ChunkTransfer.send(fileURL: url, metadata: metadata)
        return true
    }
}

// MARK: - ChunkTransfer

/// `WCSession.transferFile`まわりの共通処理。sidecar(`<file>.json`)にmetadataを書いてから転送し、
/// 転送完了で両方消す。sidecarがあるおかげで、送信できないまま次回起動を迎えた小片も
/// metadataを失わずに再送できる。`WCSession`のAPI自体はスレッドセーフなのでactor化不要。
enum ChunkTransfer {
    private static func sidecarURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("json")
    }

    /// sidecarを書いてから`transferFile`を呼ぶ。sidecarの書き込みに失敗しても転送自体は試みる
    /// （その場合は再送に必要なmetadataが復元できないだけで、初回の転送は失敗しない）。
    static func send(fileURL: URL, metadata: WatchChunkMetadata) {
        if let data = try? JSONSerialization.data(withJSONObject: metadata.metadata) {
            try? data.write(to: sidecarURL(for: fileURL))
        }
        WCSession.default.transferFile(fileURL, metadata: metadata.metadata)
    }

    /// 転送完了後の後始末。
    static func cleanup(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: sidecarURL(for: fileURL))
    }

    /// 起動時: `directory`配下に残っている`.m4a`のうちsidecarからmetadataを復元できるものを
    /// 再送キューに入れる。復元できない孤児（sidecarが無い/壊れている）は掃除のため削除する。
    /// 戻り値: 再送をキューした件数（`pendingTransfers`の初期値に使う）。
    @discardableResult
    static func resendLeftovers(in directory: URL) -> Int {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else {
            return 0
        }
        var queued = 0
        for url in files where url.pathExtension == "m4a" {
            let sidecar = sidecarURL(for: url)
            guard
                let data = try? Data(contentsOf: sidecar),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let metadata = WatchChunkMetadata(metadata: object)
            else {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: sidecar)
                continue
            }
            WCSession.default.transferFile(url, metadata: metadata.metadata)
            queued += 1
        }
        return queued
    }
}
