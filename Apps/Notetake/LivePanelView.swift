import AppKit
import SwiftUI
import NotetakeCore

/// ライブパネル（"live"ウィンドウ）。収録中のutteranceをリアルタイムに表示し、
/// コピー・話者改名・常に前面表示を提供する。
struct LivePanelView: View {
    let appModel: AppModel
    @State private var floating = false

    private static let bottomAnchorID = "bottom"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    private static let nextRotationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter
    }()

    /// mic → system → watchの順で並べたvolatile行。
    private var orderedVolatile: [(source: Source, text: String)] {
        [Source.mic, .system, .watch].compactMap { source in
            appModel.volatile[source].map { (source, $0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("セッション開始") { appModel.startRecording() }
                        .disabled(appModel.outputDirectory == nil || appModel.isRecording)
                    Button("セッション終了") { appModel.stopRecording() }
                        .disabled(!appModel.isRecording)
                    Button("区切る") { appModel.rotateRecording() }
                        .disabled(!appModel.isRecording)
                    Button("整形") { appModel.polishLastRecording() }
                        .disabled(appModel.lastFinishedPrefix == nil || appModel.isPolishing)
                    Toggle("常に前面", isOn: $floating)
                        .onChange(of: floating) {
                            applyFloating(floating)
                        }
                    Button("全文コピー") { appModel.copyAllToPasteboard() }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appModel.utterances) { utterance in
                            UtteranceRow(utterance: utterance, appModel: appModel, timeFormatter: Self.timeFormatter)
                        }
                        ForEach(orderedVolatile, id: \.source) { entry in
                            VolatileRow(source: entry.source, text: entry.text)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding()
                }
                .textSelection(.enabled)
                .onChange(of: appModel.utterances.count) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: orderedVolatile.map(\.text).joined()) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard appModel.isRecording else { return "セッション無し" }
        var text = "セッション中 \(appModel.prefix ?? "")"
        if !appModel.sources.isEmpty {
            text += " " + appModel.sources.map(\.rawValue).joined(separator: "/")
        }
        if let nextRotationAt = appModel.nextRotationAt {
            text += " 次の区切り " + Self.nextRotationFormatter.string(from: nextRotationAt)
        }
        if let inputName = appModel.inputName {
            text += " 入力: \(inputName)（空間: \(appModel.inputSpatial == true ? "対応" : "非対応")）"
        }
        if !appModel.connectedPeers.isEmpty {
            text += " 接続: " + appModel.connectedPeerNames.joined(separator: "/")
        }
        return text
    }

    private func applyFloating(_ isFloating: Bool) {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "live" }
            ?? NSApp.windows.first { $0.title == "ライブ" }
        window?.level = isFloating ? .floating : .normal
    }
}

/// 1件のutteranceを表示する行。話者名がクリック可能な場合はpopoverで改名する。
private struct UtteranceRow: View {
    let utterance: Utterance
    let appModel: AppModel
    let timeFormatter: DateFormatter

    @State private var showRenamePopover = false
    @State private var nameDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeFormatter.string(from: Date(timeIntervalSince1970: Double(utterance.start) / 1000)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let speakerID = utterance.speakerID {
                Button(utterance.speaker) {
                    nameDraft = utterance.speaker
                    showRenamePopover = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .fontWeight(.semibold)
                .popover(isPresented: $showRenamePopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("話者名", text: $nameDraft)
                            .onSubmit { confirmRename(speakerID: speakerID) }
                        Button("確定") { confirmRename(speakerID: speakerID) }
                    }
                    .padding()
                    .frame(minWidth: 200)
                }
            } else {
                Text(utterance.speaker)
                    .fontWeight(.semibold)
            }
            Text(LocationLabel.text(for: utterance))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(utterance.text)
        }
    }

    private func confirmRename(speakerID: String) {
        appModel.renameSpeaker(id: speakerID, name: nameDraft)
        showRenamePopover = false
    }
}

/// 認識中（未確定）のsource単位のテキスト行。
private struct VolatileRow: View {
    let source: Source
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(source.rawValue)
                .foregroundStyle(.secondary)
            Text(text)
                .italic()
                .foregroundStyle(.secondary)
        }
    }
}
