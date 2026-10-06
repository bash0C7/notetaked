import Foundation

/// メニューとライブパネルの操作ボタンの有効無効と、整形の状態文。両方の画面がこの1つの関数から作る
public struct RecordingControls: Equatable, Sendable {
    public var canStart: Bool
    public var canStop: Bool
    public var canRotate: Bool
    public var canPolish: Bool
    /// 整形が使えない理由、または暫定版を整形する旨
    public var polishNote: String?

    /// - 整形は確定処理が終わった収録に使える。確定待ち・確定中・再試行待ちの間は使えない。
    ///   確定を諦めた収録では暫定版を整形する。状態が分からない収録（確定処理の対象外）は暫定版を整形する
    public init(
        isRecording: Bool, hasOutputDirectory: Bool, isPolishing: Bool, lastFinishedPrefix: String?,
        finalizeStates: [String: FinalizeStateEvent]
    ) {
        canStart = hasOutputDirectory && !isRecording
        canStop = hasOutputDirectory && isRecording
        canRotate = isRecording
        guard let lastFinishedPrefix else {
            canPolish = false
            polishNote = nil
            return
        }
        if isPolishing {
            canPolish = false
            polishNote = "整形中"
            return
        }
        switch finalizeStates[lastFinishedPrefix]?.phase {
        case .waiting, .running:
            canPolish = false
            polishNote = "確定処理が終わるまで整形できません"
        case .failed:
            canPolish = false
            polishNote = "確定処理の再試行を待っています"
        case .gaveUp:
            canPolish = true
            polishNote = "確定を諦めたため、暫定版を整形します"
        case .finalized, nil:
            canPolish = true
            polishNote = nil
        }
    }
}
