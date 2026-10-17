import Testing
@testable import NotetakeCore

@Suite struct MicMonitorPolicyTests {
    @Test func monitorsWhenVisibleAndIdle() {
        #expect(MicMonitorPolicy.shouldMonitor(windowVisible: true, isRecording: false, isStartPending: false))
    }

    @Test func doesNotMonitorWhenHidden() {
        #expect(!MicMonitorPolicy.shouldMonitor(windowVisible: false, isRecording: false, isStartPending: false))
    }

    @Test func doesNotMonitorWhileRecording() {
        #expect(!MicMonitorPolicy.shouldMonitor(windowVisible: true, isRecording: true, isStartPending: false))
    }

    @Test func doesNotMonitorWhenHiddenAndRecording() {
        #expect(!MicMonitorPolicy.shouldMonitor(windowVisible: false, isRecording: true, isStartPending: false))
    }

    @Test func doesNotMonitorWhileAStartIsPending() {
        #expect(!MicMonitorPolicy.shouldMonitor(windowVisible: true, isRecording: false, isStartPending: true))
    }
}
