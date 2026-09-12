# HANDOFF — Notetake / notetaked

## 状態（2026-09-13 進行中）

- **進行中**。作業branch `m0-m2-mac-core`。Task 13まで完了（daemonは`serve`/`render`まで動作、e2e済み、commit `1200f3e`）。Task 14（mac app）を実装中
- `main`はdocs（spec / plan）のみ。実装は全て`m0-m2-mac-core`にある

## ドキュメント

- 設計spec: `docs/superpowers/specs/2026-09-12-notetake-design.md`
- 実装計画（M0〜M2、16 task）: `docs/superpowers/plans/2026-09-12-m0-m2-mac-core.md`
- SDD ledger（git管理外、このMacのみ）: `.superpowers/sdd/2026-09-12-m0-m2-mac-core/progress.md` — rulings・deferred minors・各taskの状態・review packageとreportの置き場。task briefは同dirの`task-N-brief.md`、implementer reportは`task-N-report.md`

## 進捗

| Task | 内容 | 状態 |
|---|---|---|
| 1〜3 | M0 bootstrap（SwiftPM / XcodeGen / mac・iOS・watchOS skeleton） | complete |
| 4〜8 | M1 NotetakeCore（モデル・NDJSON・TextSimilarity・Reconciler・Renderer・SessionStore） | complete |
| 9 | 制御メッセージ Command / Event | complete |
| 10 | AudioLevel / AudioConverter / Transcriber(SpeechAnalyzer) / `transcribe` subcommand | complete（fix round 1済み、commit `2283309`） |
| 11〜13 | MicCapture / SystemAudioCapture(process tap) / serve・render（stdio制御、e2e済み） | complete |
| 14 | mac app（DaemonClient / AppModel / 設定 / メニュー） | 実装中 |
| 15〜16 | ライブパネル → TCC帰属確認 | 未着手 |

`swift test`は45/45通過。`make app`でNotetake.appにnotetakedを内包したビルドが通る。

## Task 10 fix round 1 の指摘と裁定（完了済み。記録として残す）

1. [Important, plan-mandated] `Sources/NotetakeCore/Audio/AudioConverter.swift:35-44` の block-based `convert(to:error:withInputFrom:)` closure が Swift 6 の `@Sendable` capture warning を出し build 出力が非pristine。裁定: 入力bufferを`let`で束縛し、供給済みflagは`nonisolated(unsafe) var`のlocal等で持ち、warningを0件にする。`-suppress-warnings` / `@unchecked` / 包括的な`@preconcurrency`で隠さない
2. [Important] `Sources/NotetakeCore/Transcribe/Transcriber.swift:107-113` の results 消費 loop が `catch` で error を捨て `continuation.finish()` だけ行う。裁定: interface（`start() async throws -> AsyncStream<TranscriptPiece>` / `finish() async throws`）は維持し、errorをactor内に保持して`finish()`がrethrowする（finalize自体のerrorも先に起きた方を伝播）。`transcribe` subcommand は非0 exit になる

確認コマンド: `swift build 2>&1 | grep -i warning`（出力なし）/ `rm -rf .build && swift test`（45/45、warningなし）/ `make daemon && say -v Kyoko -o /tmp/nt/test.aiff "明日の会議は十時からです" && .build/release/notetaked transcribe /tmp/nt/test.aiff`（`明日の会議`を含む行、exit 0）。commit subject: `fix(core): silence Sendable warnings in AudioConverter and surface transcriber failures`。deferred minor（最終reviewで判断）: convert毎の`reset()`によるchunk境界の不連続 / `start()`前の`feed`が黙ってno-op / `start()`二重呼び出しでcontinuationが漏れる

## 再開手順

1. `git switch m0-m2-mac-core`（再開時にcheckoutが`main`へ移っていたことがある）
2. `superpowers:subagent-driven-development`を起動し、ledger先頭行がこのplanを指すことを確認。ledgerの最終行が示すtaskから再開する（implementer dispatch中に中断した場合は、そのtaskのreport fileの有無でDONEかを判断し、無ければfresh implementerへ再dispatch）
3. モデル分担（user指定、token効率のため）: 全体検討・制御・統合=Fable（controller本体）、コード記述=Sonnet subagent、決定論的コマンド実行（build / test / xcodegen / xcodebuild / devicectl / git read系）=Haiku subagent、task review=Sonnet、小さなfix再review=Haiku、最終whole-branch review=Fable。repo直下の`CLAUDE.md`にも同じ分担を記載（毎セッション自動読込）
5. ledger（`.superpowers/sdd/...`）は`.git/info/exclude`で除外された機械ローカルのfile。無ければSDD skillの手順で新規作成し、本HANDOFFの進捗表を初期状態にする
4. commit trailer: `Co-Authored-By: <model名> <noreply@anthropic.com>` + `Claude-Session: <session URL>`

## 環境の注意

- **Apple Development証明書が失効**（`spctl`: `CSSMERR_TP_CERT_REVOKED`）。失効証明書で署名したバイナリはmacOSがマルウェア警告を出して起動を止める（既知・無害）。daemonとmac appはad-hoc署名で進めている（`Makefile`の`DAEMON_IDENTITY ?= -`、`Apps/project.yml`のmac targetは`CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`）。**user作業**: Xcode > Settings > Accounts > Manage Certificates で再発行（M5のiPhone実機ビルドまでに必須）。再発行後は`DAEMON_IDENTITY=<SHA-1>`を渡し、project.ymlの署名設定を戻す
- Bash sandboxで`~/.gitconfig`と`~/.config/gh`が読めないことがある（stow経由のiCloud dotfiles）。gitは`GIT_CONFIG_GLOBAL=/dev/null`で回避、repo localにuser.name/email設定済み。`gh`はsandbox無効化が必要
- ja-JP音声モデルはダウンロード済み。日本語TTS voiceはKyoko / Otoya
- TCC: Task 11（マイク）とTask 12（システム音声）の初回実行で許可ダイアログが出る。Claude Codeを動かしているterminal appに対して出るのでuserが許可する

## 検証コマンド

- `make test` / `make daemon` / `make project` / `make app`
- `.build/release/notetaked transcribe /tmp/nt/test.aiff`（`say -v Kyoko -o /tmp/nt/test.aiff "明日の会議は十時からです"`で生成）

## 次にやること

Task 14〜15（mac app / ライブパネル。user: 画面確認）→ Task 16（TCC帰属確認。user: ダイアログ主体の報告）→ 最終whole-branch review（Fable）→ `finishing-a-development-branch` → M3以降は`writing-plans`で再計画

## GitHub

- public repo: https://github.com/bash0C7/notetaked（default `main`、作業branch `m0-m2-mac-core` もpush済み）
