import AppKit
import SwiftUI
import NotetakeCore

/// ライブパネル（"live"ウィンドウ）。収録中のutteranceをリアルタイムに表示し、
/// コピー・話者改名・常に前面表示を提供する。
struct LivePanelView: View {
    let appModel: AppModel
    @State private var floating = false
    @State private var availableInputDevices: [InputDevice] = []

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
            WrappingLayout(spacing: 8, lineSpacing: 6) {
                Button("セッション開始") { appModel.startRecording() }
                    .disabled(!appModel.recordingControls.canStart)
                Button("セッション終了") { appModel.stopRecording() }
                    .disabled(!appModel.recordingControls.canStop)
                Button("区切る") { appModel.rotateRecording() }
                    .disabled(!appModel.recordingControls.canRotate)
                Button("整形") { appModel.polishLastRecording() }
                    .disabled(!appModel.recordingControls.canPolish)
                if let polishNote = appModel.recordingControls.polishNote {
                    Text(polishNote)
                        .foregroundStyle(.secondary)
                }
                Toggle("常に前面", isOn: $floating)
                    .onChange(of: floating) {
                        applyFloating(floating)
                    }
                Button("全文コピー") { appModel.copyAllToPasteboard() }
                Picker("入力デバイス", selection: inputDeviceSelection) {
                    ForEach(availableInputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .fixedSize()
                .onAppear {
                    // 内蔵マイクを先頭へ、他は元の順のまま並べる
                    let inputs = InputDeviceProbe.selectableInputs()
                    availableInputDevices = inputs.filter { $0.uid == InputDeviceResolution.builtInUID }
                        + inputs.filter { $0.uid != InputDeviceResolution.builtInUID }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appModel.utterances) { utterance in
                            UtteranceRow(utterance: utterance, timeFormatter: Self.timeFormatter)
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
            Divider()
            StatusArea(appModel: appModel, statusText: statusText)
        }
        .frame(minWidth: 480, minHeight: 460)
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

    /// `appModel.preferredInputDeviceUID`（`nil`=内蔵マイク）と、Pickerのtag（内蔵マイクのUID）を
    /// 橋渡しするbinding。選択したら即座に確定してdaemonへ反映する
    private var inputDeviceSelection: Binding<String> {
        Binding(
            get: { appModel.preferredInputDeviceUID ?? InputDeviceResolution.builtInUID },
            set: { newValue in
                appModel.preferredInputDeviceUID = newValue == InputDeviceResolution.builtInUID ? nil : newValue
                appModel.ensureDaemon()
            }
        )
    }

    private func applyFloating(_ isFloating: Bool) {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "live" }
            ?? NSApp.windows.first { $0.title == "ライブ" }
        window?.level = isFloating ? .floating : .normal
    }
}

/// 子viewを左から並べ、幅に収まらなければ次の行へ折り返すレイアウト。
/// 操作の行を横スクロールや`>>`に隠さず、最小幅でも全部のコントロールを見せるために使う。
private struct WrappingLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? .infinity
        let frames: [CGRect] = arrange(maxWidth: maxWidth, subviews: subviews)
        let width: CGFloat = frames.map(\.maxX).max() ?? 0
        let height: CGFloat = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames: [CGRect] = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = CGPoint(x: bounds.minX + frames[index].minX, y: bounds.minY + frames[index].minY)
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(frames[index].size))
        }
    }

    /// 各子viewの位置と大きさを、行の先頭を(0, 0)として求める。行内は縦中央ぞろえ
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var lineStart: Int = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size: CGSize = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                centerLine(&frames, from: lineStart, height: lineHeight)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
                lineStart = index
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        centerLine(&frames, from: lineStart, height: lineHeight)
        return frames
    }

    private func centerLine(_ frames: inout [CGRect], from start: Int, height: CGFloat) {
        for index in start..<frames.count {
            let offset: CGFloat = (height - frames[index].height) / 2
            frames[index].origin.y += offset
        }
    }
}

/// 1件のutteranceを表示する行。収録中の発話には話者が付かないため、命名は「収録の話者」windowで行う。
private struct UtteranceRow: View {
    let utterance: Utterance
    let timeFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeFormatter.string(from: Date(timeIntervalSince1970: Double(utterance.start) / 1000)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(utterance.speaker).fontWeight(.semibold)
            Text(LocationLabel.text(for: utterance))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(utterance.text)
        }
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
