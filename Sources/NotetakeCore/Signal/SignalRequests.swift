import Foundation

/// Macが溜める、iPhoneへの体の状態と地点の要求
public struct SignalRequest: Codable, Sendable, Equatable {
    public var id: String
    public var prefix: String
    /// 要求を作った時の出力先。保存先を変えると`serve`が再起動するので、応答はこちらへ書く
    public var outputDirectory: String
    /// 収録全体の区間。`signals.jsonl`のheaderに書く
    public var recordingStartMS: Int64
    public var recordingEndMS: Int64
    /// この要求で求める区間。24時間以内で、境目は10分の格子に揃える
    public var startMS: Int64
    public var endMS: Int64
    /// 1は収録の終了直後、2はWatchの心拍が遅れて同期された分を拾う30分後
    public var round: Int
    public var createdAtMS: Int64
    /// 壁時計。再起動やMacのスリープをまたいでも、遅れた分は次の機会に送る
    public var dueAtMS: Int64
    public var failureCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case prefix
        case outputDirectory = "output_directory"
        case recordingStartMS = "recording_start_ms"
        case recordingEndMS = "recording_end_ms"
        case startMS = "start_ms"
        case endMS = "end_ms"
        case round
        case createdAtMS = "created_at_ms"
        case dueAtMS = "due_at_ms"
        case failureCount = "failure_count"
    }

    public init(
        id: String, prefix: String, outputDirectory: String, recordingStartMS: Int64, recordingEndMS: Int64,
        startMS: Int64, endMS: Int64, round: Int, createdAtMS: Int64, dueAtMS: Int64, failureCount: Int
    ) {
        self.id = id
        self.prefix = prefix
        self.outputDirectory = outputDirectory
        self.recordingStartMS = recordingStartMS
        self.recordingEndMS = recordingEndMS
        self.startMS = startMS
        self.endMS = endMS
        self.round = round
        self.createdAtMS = createdAtMS
        self.dueAtMS = dueAtMS
        self.failureCount = failureCount
    }
}

public struct SignalRequestState: Codable, Sendable, Equatable {
    public var requests: [SignalRequest]
    /// 要求を送るiPhone。最初に`signal`を名乗った1台に固定する
    public var pinnedDevice: String?
    /// 固定した時のiPhoneの名前。appの入れ直しでdevice idが変わった時に、同じiPhoneと見分ける
    public var pinnedDeviceName: String?

    enum CodingKeys: String, CodingKey {
        case requests
        case pinnedDevice = "pinned_device"
        case pinnedDeviceName = "pinned_device_name"
    }

    public init(requests: [SignalRequest] = [], pinnedDevice: String? = nil, pinnedDeviceName: String? = nil) {
        self.requests = requests
        self.pinnedDevice = pinnedDevice
        self.pinnedDeviceName = pinnedDeviceName
    }
}

/// `state/signal-requests.json`。書き込みはアトミック
public struct SignalRequestStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func `default`() -> SignalRequestStore {
        SignalRequestStore(url: CaptureStatePaths.stateDirectory().appendingPathComponent("signal-requests.json"))
    }

    /// ファイルが無ければ空。解釈できなければthrowする
    public func load() throws -> SignalRequestState {
        try JSONFile.read(SignalRequestState.self, from: url) ?? SignalRequestState()
    }

    public func save(_ state: SignalRequestState) throws {
        try JSONFile.write(state, to: url)
    }
}

/// 収録の終了で作る要求
public enum SignalPlanner {
    public static let secondRoundDelayMS: Int64 = 30 * 60_000
    public static let maxSliceMS: Int64 = 24 * 3_600_000
    public static let expiryMS: Int64 = 7 * 24 * 3_600_000

    /// 区間を24時間以内（境目は10分の格子）に分け、それぞれに1回目と2回目を作る
    public static func requests(
        prefix: String, outputDirectory: String, startMS: Int64, endMS: Int64, nowMS: Int64,
        makeID: () -> String = { UUID().uuidString }
    ) -> [SignalRequest] {
        guard endMS > startMS else { return [] }
        var slices: [(start: Int64, end: Int64)] = []
        var sliceStart = startMS
        while sliceStart < endMS {
            let limit = sliceStart + maxSliceMS
            let aligned = limit / SignalBucketing.bucketMS * SignalBucketing.bucketMS
            let sliceEnd = Swift.min(endMS, aligned > sliceStart ? aligned : limit)
            slices.append((sliceStart, sliceEnd))
            sliceStart = sliceEnd
        }
        return slices.flatMap { slice in
            [(1, nowMS), (2, nowMS + secondRoundDelayMS)].map { round, due in
                SignalRequest(
                    id: makeID(), prefix: prefix, outputDirectory: outputDirectory, recordingStartMS: startMS,
                    recordingEndMS: endMS, startMS: slice.start, endMS: slice.end, round: round, createdAtMS: nowMS,
                    dueAtMS: due, failureCount: 0)
            }
        }
    }

    /// 同じ収録・同じ区間・同じ回の要求は、先にあった方を残して1件に畳む
    public static func adding(_ new: [SignalRequest], to state: SignalRequestState) -> SignalRequestState {
        var result = state
        for request in new
        where !result.requests.contains(where: {
            $0.prefix == request.prefix && $0.startMS == request.startMS && $0.round == request.round
        }) {
            result.requests.append(request)
        }
        return result
    }
}

public struct SignalPeer: Sendable, Equatable {
    public var device: String
    public var supportsSignal: Bool

    public init(device: String, supportsSignal: Bool) {
        self.device = device
        self.supportsSignal = supportsSignal
    }
}

/// いつ・どの要求を・どのiPhoneへ送るか
public enum SignalDispatch {
    /// 最初に`signal`を名乗ったiPhoneへ固定する。固定先と別のidでも、記録した名前が同じなら、
    /// appの入れ直しでdevice idだけ変わった同じiPhoneとみなして移す（別の名前のiPhoneは変えない）
    public static func pin(_ state: SignalRequestState, hello: HelloMessage) -> SignalRequestState {
        guard hello.supportsSignal else { return state }
        var result = state
        if let pinned = state.pinnedDevice {
            if pinned == hello.device {
                if state.pinnedDeviceName != hello.deviceName {
                    result.pinnedDeviceName = hello.deviceName
                }
            } else if state.pinnedDeviceName == hello.deviceName {
                result.pinnedDevice = hello.device
            }
        } else {
            result.pinnedDevice = hello.device
            result.pinnedDeviceName = hello.deviceName
        }
        return result
    }

    /// 作成から7日を超えた要求を外す。iPhoneを開かない間に溜まり続けないため
    public static func expire(_ state: SignalRequestState, nowMS: Int64) -> (
        state: SignalRequestState, expired: [SignalRequest]
    ) {
        let isExpired: (SignalRequest) -> Bool = { nowMS - $0.createdAtMS > SignalPlanner.expiryMS }
        var result = state
        result.requests.removeAll(where: isExpired)
        return (result, state.requests.filter(isExpired))
    }

    /// 次に送る要求。送信中の要求があれば送らない。固定したiPhoneが`signal`を名乗って接続している時だけ送る
    public static func decide(
        state: SignalRequestState, peers: [SignalPeer], inFlight: Bool, nowMS: Int64
    ) -> SignalRequest? {
        guard !inFlight, let pinned = state.pinnedDevice,
            peers.contains(where: { $0.device == pinned && $0.supportsSignal })
        else { return nil }
        return state.requests.filter { $0.dueAtMS <= nowMS }.min {
            ($0.dueAtMS, $0.createdAtMS, $0.startMS) < ($1.dueAtMS, $1.createdAtMS, $1.startMS)
        }
    }
}
