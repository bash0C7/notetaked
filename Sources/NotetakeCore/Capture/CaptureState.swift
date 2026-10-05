import Foundation

/// serveがcapture-daemonへ伝える望む状態（`capture-desired.json`）。収録中でなければ`recording`がnil
public struct CaptureDesiredState: Codable, Equatable, Sendable {
    public struct Recording: Codable, Equatable, Sendable {
        public var prefix: String
        /// 生音声ディレクトリの絶対path
        public var directory: String

        public init(prefix: String, directory: String) {
            self.prefix = prefix
            self.directory = directory
        }
    }

    public static let stopped = CaptureDesiredState(recording: nil, sources: [], pinnedInputUID: nil)

    public var recording: Recording?
    public var sources: [Source]
    /// micを固定する入力機器のUID。nilなら既定の入力を使う
    public var pinnedInputUID: String?

    enum CodingKeys: String, CodingKey {
        case recording
        case sources
        case pinnedInputUID = "pinned_input_uid"
    }

    public init(recording: Recording?, sources: [Source], pinnedInputUID: String?) {
        self.recording = recording
        self.sources = sources
        self.pinnedInputUID = pinnedInputUID
    }
}

/// capture-daemonが1秒ごとに書く実状態（`capture-actual.json`）。ファイルの更新時刻がcapture-daemonの心拍を兼ねる
public struct CaptureActualState: Codable, Equatable, Sendable {
    public struct SourceStatus: Codable, Equatable, Sendable {
        public var source: Source
        public var state: CaptureSourceState
        /// `retrying`の理由
        public var reason: String?
        public var input: InputDevice?
        /// 固定した入力機器が外れ、既定の入力で取り込んでいる
        public var fellBackFromPinned: Bool
        /// 最後に起きた書き込みや変換の失敗
        public var lastError: String?

        enum CodingKeys: String, CodingKey {
            case source
            case state
            case reason
            case input
            case fellBackFromPinned = "fell_back_from_pinned"
            case lastError = "last_error"
        }

        public init(
            source: Source, state: CaptureSourceState, reason: String? = nil, input: InputDevice? = nil,
            fellBackFromPinned: Bool = false, lastError: String? = nil
        ) {
            self.source = source
            self.state = state
            self.reason = reason
            self.input = input
            self.fellBackFromPinned = fellBackFromPinned
            self.lastError = lastError
        }
    }

    public var pid: Int32
    /// いま書いている収録。止まっていればnil
    public var prefix: String?
    public var sources: [SourceStatus]
    /// 書いた時刻（epoch ms）
    public var updated: Int64

    public init(pid: Int32, prefix: String?, sources: [SourceStatus], updated: Int64) {
        self.pid = pid
        self.prefix = prefix
        self.sources = sources
        self.updated = updated
    }
}

/// capture-daemonが望む状態のファイルを見張る。更新時刻が変わった時だけ読み直す
public struct DesiredStateWatcher: Sendable {
    public enum Change: Equatable, Sendable {
        case changed(CaptureDesiredState)
        /// 中身を解釈できない。capture-daemonは今の取り込みを変えずに続ける
        case unreadable(String)
    }

    private let url: URL
    private var checked = false
    private var lastModified: Date?
    private var lastStatFailure: String?

    public init(url: URL) {
        self.url = url
    }

    /// 最初の呼び出しと、前回から更新時刻が変わった時だけ値を返す。ファイルが無いのは停止中として扱う。
    /// 更新時刻を取れない他の失敗は停止とせず、`unreadable`として同じ失敗を1度だけ返す
    public mutating func poll() -> Change? {
        let modified: Date?
        do {
            modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            lastStatFailure = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            modified = nil
            lastStatFailure = nil
        } catch {
            // 説明文には毎回変わる値が入るため、同じ失敗かどうかはdomainとcodeで見分ける
            let kind = "\((error as NSError).domain) \((error as NSError).code)"
            guard kind != lastStatFailure else { return nil }
            lastStatFailure = kind
            return .unreadable("\(error)")
        }
        if checked, modified == lastModified {
            return nil
        }
        checked = true
        lastModified = modified
        guard modified != nil else {
            return .changed(.stopped)
        }
        do {
            return .changed(try JSONFile.read(CaptureDesiredState.self, from: url) ?? .stopped)
        } catch {
            return .unreadable("\(error)")
        }
    }
}
