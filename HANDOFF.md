# HANDOFF — Notetake / notetaked

## 状態（2026-09-12 中断）

- **中断**。作業branch `m0-m2-mac-core`、HEAD `360482d`（Task 10まで実装・commit済み。Task 10はreview済み、fix round 1未実施）
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
| 10 | AudioLevel / AudioConverter / Transcriber(SpeechAnalyzer) / `transcribe` subcommand | commit `360482d`、**review済み・fix round 1未実施**（Important 2件: AudioConverterの@Sendable warning、Transcriberのresults loopでerror握り潰し。詳細と裁定はledger） |
| 11〜16 | MicCapture → SystemAudioCapture → serve/render → mac app → ライブパネル → TCC確認 | 未着手 |

`swift test`は45/45通過。`make app`でNotetake.appにnotetakedを内包したビルドが通る。

## 再開手順

1. `git switch m0-m2-mac-core`（再開時にcheckoutが`main`へ移っていたことがある）
2. `superpowers:subagent-driven-development`を起動し、ledger先頭行がこのplanを指すことを確認。Task 10のfix round 1から再開: implementer（Sonnet）にledger記載のImportant 2件と裁定を渡す → `scripts/review-package <plan> 360482d HEAD` → 再review（Haiku）→ complete → Task 11へ
3. モデル分担（user指定）: 実装=Sonnet、task review=Sonnet、小さなfix再review=Haiku、最終whole-branch review=Fable、決定論的コマンドはHaiku
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

Task 10 fix round 1 → 再review → Task 11（MicCapture / CaptureStream / `capture`。user: マイク許可）→ Task 12（system audio tap。user: 許可）→ Task 13（serve / render、`say`によるe2e）→ Task 14〜15（mac app / ライブパネル。user: 画面確認）→ Task 16（TCC帰属確認。user: ダイアログ主体の報告）→ 最終whole-branch review（Fable）→ `finishing-a-development-branch` → M3以降は`writing-plans`で再計画

## 未完了のuser作業

- **GitHub public repoの作成とpush**: このセッションのprocessはiCloud Drive配下（stow経由の`~/.gitconfig`と`~/.config/gh`）を読めず（macOSの「ファイルとフォルダ」権限）、`gh`が起動できない。userが自分のTerminalで次を実行する:
  ```bash
  cd ~/dev/src/github.com/bash0C7/notetaked
  gh repo create bash0C7/notetaked --public --source=. --remote=origin \
    --description "常駐マルチデバイス文字起こし: macOS menu bar app + daemon / iPhone / Watch, Apple on-device Speech"
  git push -u origin main && git push -u origin m0-m2-mac-core
  ```
  または、Claude Codeを動かすterminal appにSystem設定 > プライバシーとセキュリティ > ファイルとフォルダ > iCloud Drive の許可を与えれば、次回セッションでClaudeが実行できる
