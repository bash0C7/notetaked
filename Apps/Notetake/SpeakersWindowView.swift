import NotetakeCore
import SwiftUI

/// 「収録の話者」window。出力ディレクトリの収録を新しい順に並べ、確定済みの収録の話者の改名、
/// まとめる、人数を指定した確定し直しを行う。
struct SpeakersWindowView: View {
    let appModel: AppModel
    @State private var entries: [RecordingEntry] = []
    @State private var selectedPrefix: String?
    @State private var selectedSpeakers: Set<String> = []
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var specifiesCount = false
    @State private var speakerCount = 2

    private var selectedEntry: RecordingEntry? {
        entries.first { $0.prefix == selectedPrefix }
    }

    var body: some View {
        HSplitView {
            List(entries, selection: $selectedPrefix) { entry in
                VStack(alignment: .leading) {
                    Text(entry.title)
                    Text(RecordingCatalog.statusText(entry: entry, state: appModel.finalizeStates[entry.prefix]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.prefix)
            }
            .accessibilityIdentifier("speakers-recordings")
            .frame(minWidth: 220, idealWidth: 240)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: reloadKey) { await reload() }
        .onChange(of: selectedPrefix) {
            selectedSpeakers = []
            renamingID = nil
        }
    }

    /// 一覧を読み直す契機。値が変わるたびに`.task`が走り直る
    private var reloadKey: String {
        let states = appModel.finalizeStates.values
            .sorted { $0.prefix < $1.prefix }
            .map { "\($0.prefix):\($0.phase.rawValue):\($0.run ?? 0)" }
            .joined(separator: ",")
        return "\(appModel.speakersRevision)|\(appModel.outputDirectory?.path ?? "")|\(states)"
    }

    private func reload() async {
        guard let directory = appModel.outputDirectory else {
            entries = []
            return
        }
        let scanned = await Task.detached(priority: .userInitiated) {
            RecordingCatalog.scan(outputDirectory: directory)
        }.value
        guard !Task.isCancelled else { return }
        entries = scanned
        if let selectedPrefix, !scanned.contains(where: { $0.prefix == selectedPrefix }) {
            self.selectedPrefix = nil
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                if entry.finalizedRun != nil {
                    speakersList(entry)
                } else {
                    Text("確定済みの収録を選ぶと話者の一覧が出ます")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
                refinalizeControls(entry)
            }
            .padding()
        } else {
            Text("収録を選んでください")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func speakersList(_ entry: RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("まとめる") {}
                    .hidden()
                    .overlay { mergeMenu(entry) }
                Spacer()
            }
            List(entry.speakers, id: \.id, selection: $selectedSpeakers) { speaker in
                HStack(alignment: .top, spacing: 8) {
                    Button(speaker.displayName) {
                        renameText = speaker.name ?? ""
                        renamingID = speaker.id
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("rename-\(speaker.id)")
                    .popover(
                        isPresented: Binding(
                            get: { renamingID == speaker.id },
                            set: { if !$0, renamingID == speaker.id { renamingID = nil } })
                    ) {
                        renamePopover(prefix: entry.prefix, id: speaker.id)
                    }
                    Text(speaker.source.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DurationLabel.text(seconds: speaker.speechSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(speaker.excerpt)
                        .lineLimit(2)
                }
                .tag(speaker.id)
            }
            .accessibilityIdentifier("speakers-list")
        }
    }

    /// ちょうど2人を選んだ時だけ有効。どちらへまとめるかを選ぶ
    private func mergeMenu(_ entry: RecordingEntry) -> some View {
        let chosen = entry.speakers.filter { selectedSpeakers.contains($0.id) }
        return Menu("まとめる") {
            ForEach(chosen, id: \.id) { into in
                if let from = chosen.first(where: { $0.id != into.id }) {
                    Button("\(into.displayName)へまとめる") {
                        appModel.mergeSpeakers(prefix: entry.prefix, from: from.id, into: into.id)
                        selectedSpeakers = []
                    }
                }
            }
        }
        .disabled(chosen.count != 2)
        .accessibilityIdentifier("speakers-merge")
    }

    private func renamePopover(prefix: String, id: String) -> some View {
        HStack {
            TextField("名前", text: $renameText)
                .frame(width: 160)
                .onSubmit { commitRename(prefix: prefix, id: id) }
            Button("確定") { commitRename(prefix: prefix, id: id) }
        }
        .padding()
    }

    private func commitRename(prefix: String, id: String) {
        appModel.renameSpeaker(prefix: prefix, id: id, name: renameText)
        renamingID = nil
    }

    private func refinalizeControls(_ entry: RecordingEntry) -> some View {
        let state = appModel.finalizeStates[entry.prefix]
        let enabled = RecordingCatalog.canRefinalize(entry: entry, state: state)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("話者の人数を指定する", isOn: $specifiesCount)
                    .accessibilityIdentifier("speakers-count-toggle")
                Stepper("\(speakerCount)人", value: $speakerCount, in: 1...10)
                    .disabled(!specifiesCount)
                    .accessibilityIdentifier("speakers-count")
                Spacer()
                Button("確定し直す") {
                    appModel.refinalize(prefix: entry.prefix, speakers: specifiesCount ? speakerCount : nil)
                }
                .disabled(!enabled)
                .accessibilityIdentifier("speakers-refinalize")
            }
            if !enabled {
                Text(entry.hasRawAudio ? "確定処理が進行中です" : "生音声が残っていないため確定し直せません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
