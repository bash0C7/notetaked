# Notetake / notetaked

ツール名（daemon / ツール全体）は`notetaked`、読みは「のたてけでぃー」（ローマ字読み）。語源はnotetake（速記）+ daemonの`d`。

Macのメニューバーappとdaemonで会議音声（マイク + システム音声）をリアルタイムに文字起こしし、iPhone / Apple Watchで拾った音声も同じ収録に統合してMarkdownの議事録にする。全てローカルで動く（Speech / FluidAudio / Foundation Models）。

## 構成

| 部品 | 場所 | 役割 |
|---|---|---|
| `notetaked` | `Sources/notetaked` | daemon（CLI）。`serve`で収録・話者分離・iPhone / Watchからの受信・`final.md`生成、`polish`で対話整形、`render` / `transcribe` / `capture` |
| `NotetakeCore` | `Sources/NotetakeCore` | 共有ロジック。Segment / Reconciler / SpeakerRegistry / LocationLabel / DirectionEstimator / PeerMessage など |
| `NotetakeDiarization` | `Sources/NotetakeDiarization` | FluidAudioによる話者分離 |
| Notetake.app | `Apps/Notetake` | メニューバーapp。daemonを子processとして起動・監視・再起動・終了し、ライブパネル（本文・話者命名・区切る・整形）と設定Windowを持つ |
| NotetakeMobile | `Apps/NotetakeMobile` | iPhone app。Bonjour + TLS PSKでMacへ接続し、マイク（iPhone 16eは空間音声FOAで方位付き）の文字起こしをsegとして送る。Watchからの小片を中継する |
| NotetakeWatch | `Apps/NotetakeWatch` | Watch app。20秒のAAC小片を`WCSession.transferFile`でiPhoneへ送る |

出力（設定「保存先」、既定`~/Downloads`）: `<prefix>.live.txt` / `.timed.jsonl`（全record）/ `.final.md`（`HH:mm:ss **話者**（場所）: 本文`）/ `.speakers.json` / `.polished.md`、`orphans.jsonl`。大域の話者profileは`~/Library/Application Support/Notetake/speakers.json`。

## 必要なもの

- macOS（Apple Silicon、Apple Intelligence有効なMacで`polish`が動く）、Xcode、xcodegen
- 初回はネット: `swift package --disable-keychain --disable-netrc resolve`（FluidAudioのbinaryTarget）、FluidAudioのモデル（Hugging Face、`serve`初回）、ja-JP音声モデル
- iPhone / Watchは実機のみ（Apple Development証明書、`Apps/project.yml`のAutomatic署名）

## ビルドと検証

```bash
make verify   # 検証ゲート: swift build（警告ゼロ）→ swift test → make app → iOS + watchOSコンパイル。最終行 verify: OK
make app      # .build/DerivedData/Build/Products/Debug/Notetake.app（daemon同梱、ad-hoc署名）
make daemon   # .build/release/notetaked
make project  # Apps/Notetake.xcodeproj をxcodegenで生成
```

実機: `xcodebuild -scheme NotetakeMobile|NotetakeWatch -destination 'id=<udid>' -allowProvisioningUpdates build` → `xcrun devicectl device install app --device <udid> <app>`（`.claude/skills/device`）。

## 使い方

1. `make app`でNotetake.appを起動（`open`で開く。binary直起動はUIが壊れる）。設定Windowで保存先・自分の名前・自動で区切る間隔（時間、0で区切らない）・ペアリングコード
2. メニュー / ライブパネルの「収録開始」「収録停止」「区切る」（prefixを切り替える）「整形」（直前の収録を`polish`）。パネルの話者名クリックで命名（次回起動以降も同じ声に同じ名前が付く）
3. iPhone: Notetakeにペアリングコードを入力→「接続: <Mac名>」→「開始」。segはMacの収録に時刻で割り当てられ、切断中の分は再接続後に送られて`final.md`が再生成される
4. Watch: Notetakeで「開始」→iPhone経由でMacへ届く（`（Watch）`行）

CLI単体: `.build/release/notetaked serve --output <dir> --owner <名前> --source both [--pair-code 123456] [--no-diarize]`（stdinに`{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdoutに`status` / `utterance` / `volatile` / `peer` / `log` / `error`イベント）。

## ドキュメント

- `HANDOFF.md`: 現在の状態・環境の注意・次にやること（作業はここから）
- `docs/superpowers/specs/2026-09-12-notetake-design.md`: 全体設計（binding）。他のspec / planは`docs/superpowers/`
- `.claude/skills/`: `verify`（検証ゲート）/ `mac-app`（appの起動・メニュー・設定の自動操作）/ `device`（iPhone / Watchのインストール・起動・crash log）/ `recordings`（収録結果の確認）
- 課題: GitHub issues
