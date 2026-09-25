# notetaked — project instructions

- 作業開始時に必ず`HANDOFF.md`を読む（現在の状態・環境の注意・次にやること）。全体像は`README.md`
- **検証ゲートは`make verify`**（全targetのビルド警告ゼロ・全テスト・mac app・iOS / watchOSコンパイル）。修正はゲートの結果を全件受け取ってから行い、1件ずつ潰さない。`make verify`を通していないものをHANDOFFで「実装済み」と書かない（「未検証」と書く）。実機でしか分からない挙動は実機で確認してから「確認済み」と書く
- **モデル分担（user指定、token効率のため）**: 全体検討・制御・統合・最終whole-branch review = Fable（controller本体）/ コード記述 = Sonnet subagent / 決定論的コマンド実行（`make verify`、xcodebuild、devicectl、gitのread系）= Haiku subagent / task review = Sonnet / 小さなfix再review = Haiku。subagent dispatch時はmodelを必ず明示する。subagentはcommitしない（gitのmutate系はcontrollerが直接行う）
- 実装は`superpowers:subagent-driven-development`で進める。ledger: `.superpowers/sdd/<plan名>/progress.md`（git管理外）。spec: `docs/superpowers/specs/`、plan: `docs/superpowers/plans/`。実改修はplanをuserが承認してから
- 決定論的な作業はproject skillを使う: `verify` / `mac-app`（appの起動・メニュー・設定・話者命名の自動操作、画面撮影、既定入力の切替）/ `device`（iPhone / Watchのbuild・インストール・起動・crash log）/ `recordings`（収録結果の要約）
- 決定論的な作業で使うskillの正本はリポジトリ内の`.claude/skills/`。`.agents/`は使わない。
- daemonの状況表示・監視・起動終了はメニューバーapp（Notetake.app）が司る。CLI単体の`serve`は検証用
- 署名: iOS / watchOSは`Apps/project.yml`のAutomatic + Team（有効なApple Development証明書）。daemon / mac appはad-hoc署名（`Makefile`の`DAEMON_IDENTITY ?= -`、mac targetの`CODE_SIGN_IDENTITY: "-"`）。本物の署名へ切り替えるとTCC（マイク / システム音声）の再許可が出るので、userが画面の前にいる時に行う（手順はHANDOFF.md）。keychainに残る失効証明書で署名しない
- commit messageの末尾にCo-Authored-By / Codex-Session trailerを付ける。merge / PRのundraftはuserが切り出すまで話題にしない
- 日本語と英数字の間に空白を入れない（コード内コメント・doc・commit message本文）
