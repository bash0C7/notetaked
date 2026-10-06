import Foundation
import Testing
@testable import NotetakeCore

@Test func captureStatusLabelNamesTheSourceAndState() {
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .mic, state: .recording)) == "マイク: 取り込み中")
    #expect(
        CaptureStatusLabel.text(
            for: CaptureStatus(source: .system, state: .retrying, reason: "The stream was stopped by the system"))
            == "system音声: 再開待ち（The stream was stopped by the system）")
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .system, state: .retrying)) == "system音声: 再開待ち")
    #expect(CaptureStatusLabel.text(for: CaptureStatus(source: .mic, state: .off)) == "マイク: 停止")
}
