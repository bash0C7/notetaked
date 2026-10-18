import Foundation
import NotetakeCore
import UserNotifications

/// 録音が止まったのに画面を見ていない時のローカル通知。識別子`notetake.deadman`の1件だけを扱う。
/// 録音中は小片を閉じるたびに予約を先へ延ばし、止まってappが動けなくなっても予約が鳴る
@MainActor
final class DeadManNotifier {
    private static let identifier = "notetake.deadman"

    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false

    /// 初回の開始時に許可を求める。拒否されても録音は続ける
    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        let center = self.center
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func apply(_ action: WatchDeadManAction, nowMS: Int64) {
        switch action {
        case .schedule(let fireAtMS):
            let seconds = max(1, Double(fireAtMS - nowMS) / 1000)
            enqueue(after: seconds, body: "Watchの録音が3分止まっています。開いて再開してください")
        case .cancel:
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        case .none:
            break
        }
    }

    /// haltedへ移った時に即時（1秒後）の通知を1回出す
    func notifyHalted(reason: WatchHaltReason) {
        enqueue(after: 1, body: "録音が止まりました: \(reason.displayText)")
    }

    private func enqueue(after seconds: TimeInterval, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        let content = UNMutableNotificationContent()
        content.title = "Notetake"
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        // removePendingと呼んだ順を保つため、同期で呼ぶ
        center.add(request) { @Sendable _ in }
    }
}
