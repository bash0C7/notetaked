import NotetakeCore
import SwiftUI
import UIKit

/// 地点の登録と位置の許可
struct PlacesView: View {
    @Bindable var monitor: PlaceMonitor
    @State private var name = ""
    @State private var registering = false

    var body: some View {
        Form {
            Section("位置の許可") {
                LabeledContent("状態", value: statusText)
                LabeledContent("記録", value: monitor.isTracking ? "記録中" : "停止中")
                switch monitor.status {
                case .notDetermined:
                    Button("位置情報を許可する（使用中のみ）") { monitor.requestWhenInUse() }
                case .denied, .restricted:
                    Button("設定アプリを開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .whenInUse, .always:
                    EmptyView()
                }
                Text("Notetakeを開いている間と、iPhoneで収録している間だけ、どの地点にいたかを記録します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if monitor.isReducedAccuracy {
                    Text("「正確な位置」がオフです。半径100mの地点に当たらなくなるので、設定アプリでオンにしてください。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("ここを地点として登録") {
                TextField("名前（例: 自宅）", text: $name)
                Button(registering ? "登録中…" : "登録する") {
                    registering = true
                    Task {
                        if await monitor.registerCurrentLocation(name: name) {
                            name = ""
                        }
                        registering = false
                    }
                }
                .disabled(name.isEmpty || registering)
            }
            Section("登録地点") {
                ForEach(monitor.places) { place in
                    LabeledContent(place.name, value: "半径\(Int(place.radiusM))m")
                }
                .onDelete { monitor.removePlaces(at: $0) }
            }
            if let error = monitor.lastError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("地点")
    }

    private var statusText: String {
        switch monitor.status {
        case .always: return "常に"
        case .whenInUse: return "使用中のみ"
        case .denied: return "許可されていない"
        case .restricted: return "制限されている"
        case .notDetermined: return "未設定"
        }
    }
}
