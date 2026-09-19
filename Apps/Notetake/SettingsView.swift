import SwiftUI
import NotetakeCore

/// `Settings`シーンで表示する設定画面。保存先・自分の名前・自動で区切る間隔を編集する。
/// 自分の名前と自動で区切る間隔は、キー入力ごとではなく確定（Enter/フォーカス喪失/ウィンドウを閉じる）時に
/// のみ`appModel`へ反映する。`--owner`はdaemonの起動引数に含まれるため、確定していない値で毎回daemonを
/// 再起動しないようにするため。間隔は`RotationSchedule.normalizedIntervalHours`で正規化してから反映する。
struct SettingsView: View {
    /// Picker上で「既定（OSに合わせる）」を表す選択肢のtag（`appModel.preferredInputDeviceUID == nil`に対応）
    private static let defaultDeviceTag = ""

    @Bindable var appModel: AppModel
    @State private var ownerNameDraft: String = ""
    @FocusState private var ownerNameFieldFocused: Bool
    @State private var rotationIntervalDraft: String = ""
    @FocusState private var rotationFieldFocused: Bool
    @State private var availableInputDevices: [InputDevice] = []

    var body: some View {
        Form {
            LabeledContent("保存先") {
                HStack {
                    Text(appModel.outputDirectory?.path ?? "未設定")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { chooseOutputDirectory() }
                }
            }
            Picker("入力デバイス", selection: inputDeviceSelection) {
                Text("既定（OSに合わせる）").tag(Self.defaultDeviceTag)
                ForEach(availableInputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            TextField("自分の名前", text: $ownerNameDraft)
                .focused($ownerNameFieldFocused)
                .onSubmit { commitOwnerName() }
            LabeledContent("自動で区切る間隔") {
                HStack {
                    TextField("", text: $rotationIntervalDraft)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .focused($rotationFieldFocused)
                        .onSubmit { commitRotationInterval() }
                    Text("時間（0で区切らない）")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("ペアリングコード") {
                HStack {
                    Text(appModel.pairingCode)
                        .font(.system(.title2, design: .monospaced))
                    Button("再生成") { appModel.regeneratePairingCode() }
                }
            }
            Text("iPhoneのNotetakeでこのコードを入力")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            ownerNameDraft = appModel.ownerName
            rotationIntervalDraft = Self.formatHours(appModel.rotationIntervalHours)
            availableInputDevices = InputDeviceProbe.all()
        }
        .onChange(of: ownerNameFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitOwnerName()
            }
        }
        .onChange(of: rotationFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commitRotationInterval()
            }
        }
        .onDisappear {
            commitOwnerName()
            commitRotationInterval()
        }
        .padding()
        .frame(minWidth: 360)
    }

    /// `appModel.preferredInputDeviceUID`（`nil`=既定）と、Pickerのtag（`nil`を表せないため
    /// `Self.defaultDeviceTag`で代用）を橋渡しするbinding。選択したら即座に確定してdaemonへ反映する
    private var inputDeviceSelection: Binding<String> {
        Binding(
            get: { appModel.preferredInputDeviceUID ?? Self.defaultDeviceTag },
            set: { newValue in
                appModel.preferredInputDeviceUID = newValue == Self.defaultDeviceTag ? nil : newValue
                appModel.ensureDaemon()
            }
        )
    }

    private func commitOwnerName() {
        guard ownerNameDraft != appModel.ownerName else { return }
        appModel.ownerName = ownerNameDraft
        appModel.ensureDaemon()
    }

    private func commitRotationInterval() {
        guard let value = Double(rotationIntervalDraft.trimmingCharacters(in: .whitespaces)) else {
            rotationIntervalDraft = Self.formatHours(appModel.rotationIntervalHours)
            return
        }
        let normalized = RotationSchedule.normalizedIntervalHours(value)
        if normalized != appModel.rotationIntervalHours {
            appModel.rotationIntervalHours = normalized
        }
        rotationIntervalDraft = Self.formatHours(normalized)
    }

    /// 24→"24"、0.05→"0.05"のように、末尾の".0"を持たない簡潔な文字列にする。
    private static func formatHours(_ hours: Double) -> String {
        var text = String(hours)
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = appModel.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.outputDirectory = url
        appModel.ensureDaemon()
    }
}
