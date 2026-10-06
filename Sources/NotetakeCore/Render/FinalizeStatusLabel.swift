import Foundation

/// 確定処理の状態を、メニューと「収録の話者」windowに出す文にする
public enum FinalizeStatusLabel {
    /// 収録1つの状態の文。`finalized`の文は、確定済みの回があるか（`run`）で変わらない
    public static func text(for state: FinalizeStateEvent) -> String {
        switch state.phase {
        case .waiting:
            return "確定待ち"
        case .running:
            return "確定中" + (state.detail.map { "（\($0)）" } ?? "")
        case .finalized:
            return "確定済み"
        case .failed:
            return "確定に失敗（再試行待ち）" + (state.detail.map { ": \($0)" } ?? "")
        case .gaveUp:
            return "確定を諦めました" + (state.detail.map { ": \($0)" } ?? "")
        }
    }

    /// メニューに出す行。確定中の収録、待っている収録の数、失敗した収録を、この順に並べる。確定済みは出さない
    public static func menuLines(states: [String: FinalizeStateEvent]) -> [String] {
        let ordered = states.values.sorted { $0.prefix < $1.prefix }
        var lines: [String] = []
        for state in ordered where state.phase == .running {
            lines.append("\(state.prefix): \(text(for: state))")
        }
        let waiting = ordered.filter { $0.phase == .waiting }.count
        if waiting > 0 {
            lines.append("確定待ち \(waiting)件")
        }
        for state in ordered where state.phase == .failed || state.phase == .gaveUp {
            lines.append("\(state.prefix): \(text(for: state))")
        }
        return lines
    }
}
