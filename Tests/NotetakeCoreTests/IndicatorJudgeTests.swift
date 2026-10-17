import Testing
@testable import NotetakeCore

struct IndicatorJudgeTests {
    /// startMSから100msおきにdurationMS分、同じdBFSを足す。戻り値は次に足す時刻
    @discardableResult
    private func fill(_ history: inout LevelHistory, from startMS: Int64 = 0, durationMS: Int64, dbfs: Double) -> Int64 {
        var t = startMS
        while t < startMS + durationMS {
            history.append(atMS: t, dbfs: dbfs)
            t += 100
        }
        return t
    }

    private func input(
        _ history: LevelHistory,
        captureState: CaptureSourceState? = nil,
        captureReason: String? = nil,
        recording: Bool = true,
        recordingStartedAtMS: Int64? = 0,
        lastTextAtMS: Int64? = nil,
        nowMS: Int64
    ) -> SourceIndicatorInput {
        SourceIndicatorInput(
            history: history,
            captureState: captureState,
            captureReason: captureReason,
            recording: recording,
            recordingStartedAtMS: recordingStartedAtMS,
            lastTextAtMS: lastTextAtMS,
            nowMS: nowMS
        )
    }

    @Test func retryingIsAnAlertWithTheReason() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 1_000, dbfs: -30)
        let message = IndicatorJudge.judge(input(
            history, captureState: .retrying, captureReason: "ScreenCaptureKitへ接続しています", nowMS: now))
        #expect(message.severity == .alert)
        #expect(message.text.contains("ScreenCaptureKitへ接続しています"))
    }

    @Test func threeSecondsOfRealSilenceIsAnAlert() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 3_000, dbfs: -120)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: now, nowMS: now))
        #expect(message.severity == .alert)
        #expect(message.text == "音声がゼロです（入力が無音）")
    }

    @Test func twoPointNineSecondsOfSilenceIsNotYet() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 2_900, dbfs: -120)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: now, nowMS: now))
        #expect(message.severity == .normal)
    }

    @Test func aQuietRoomIsNormal() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 60_000, dbfs: -70)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: now - 1_000, nowMS: now))
        #expect(message.severity == .normal)
    }

    @Test func aGapRightAfterStartIsInfoNotAlert() {
        var history = LevelHistory()
        history.appendGap(atMS: 1_900)
        let message = IndicatorJudge.judge(input(history, recordingStartedAtMS: 0, nowMS: 2_000))
        #expect(message.severity == .info)
        #expect(message.text == "取得待ち")
    }

    @Test func aGapAfterTheGracePeriodIsAnAlert() {
        var history = LevelHistory()
        history.appendGap(atMS: 5_900)
        let message = IndicatorJudge.judge(input(history, recordingStartedAtMS: 0, nowMS: 6_000))
        #expect(message.severity == .alert)
        #expect(message.text == "音声が届いていません")
    }

    @Test func aGapDoesNotLetSilenceTurnRedAfterAShortSwitch() {
        var history = LevelHistory()
        let afterFirst = fill(&history, durationMS: 2_000, dbfs: -120)
        history.appendGap(atMS: afterFirst)
        let afterSecond = fill(&history, from: afterFirst + 100, durationMS: 2_000, dbfs: -120)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: afterSecond, nowMS: afterSecond))
        #expect(message.severity != .alert)
    }

    @Test func soundWithoutTextForThirtySecondsIsACaution() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 40_000, dbfs: -30)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: nil, nowMS: now))
        #expect(message.severity == .caution)
    }

    @Test func soundWithRecentTextIsNormal() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 40_000, dbfs: -30)
        let message = IndicatorJudge.judge(input(history, lastTextAtMS: now - 5_000, nowMS: now))
        #expect(message.severity == .normal)
    }

    @Test func stoppedMonitoringNeverWarnsAboutMissingText() {
        var history = LevelHistory()
        let now = fill(&history, durationMS: 40_000, dbfs: -30)
        let message = IndicatorJudge.judge(input(
            history, recording: false, recordingStartedAtMS: nil, lastTextAtMS: nil, nowMS: now))
        #expect(message.severity == .normal)
    }

    @Test func daemonSilenceBecomesAnAlertAtFifteenSeconds() {
        #expect(IndicatorJudge.judgeDaemon(lastUpdatedMS: 0, nowMS: 15_000) != nil)
        #expect(IndicatorJudge.judgeDaemon(lastUpdatedMS: 0, nowMS: 14_999) == nil)
        #expect(IndicatorJudge.judgeDaemon(lastUpdatedMS: nil, nowMS: 1_000)?.severity == .alert)
    }

    @Test func peerDisconnectAfterConnectedIsACaution() {
        let message = IndicatorJudge.judgePeer(wasConnected: true, connected: false)
        #expect(message?.severity == .caution)
        #expect(message?.text == "iPhoneとの接続が切れました")
        #expect(IndicatorJudge.judgePeer(wasConnected: false, connected: false) == nil)
        #expect(IndicatorJudge.judgePeer(wasConnected: true, connected: true) == nil)
    }
}
