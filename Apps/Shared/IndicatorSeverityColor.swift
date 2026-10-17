import NotetakeCore
import SwiftUI

extension IndicatorSeverity {
    /// 赤はalertだけ。info・normalは目立たせない
    var color: Color {
        switch self {
        case .alert: return Color.red
        case .caution: return Color.orange
        case .info, .normal: return Color.secondary
        }
    }
}
