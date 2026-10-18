import Testing
@testable import NotetakeCore

@Test func displayTextMatchesTheReducerWording() {
    #expect(WatchHaltReason.startFailed.displayText == "開始に失敗")
    #expect(WatchHaltReason.interrupted.displayText == "割り込み（通話・Siriなど）")
    #expect(WatchHaltReason.routeChanged.displayText == "音声の経路が変わった")
    #expect(WatchHaltReason.mediaServicesReset.displayText == "音声サービスの再起動")
    #expect(WatchHaltReason.writeFailed.displayText == "書き込みに失敗")
    #expect(WatchHaltReason.noAudio.displayText == "音声が途切れた")
}

@Test func autoStoppedHasItsOwnText() {
    #expect(WatchHaltReason.autoStopped.displayText == "連続録音の上限で自動停止")
    #expect(WatchHaltReason.autoStopped.rawValue == "auto_stopped")
}
