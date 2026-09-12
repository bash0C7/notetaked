# notetaked — project instructions

- 作業開始時に必ず`HANDOFF.md`を読む（現在の状態・再開手順・環境の注意・次にやること）
- **モデル分担（user指定、token効率のため）**: 全体検討・制御・統合・最終whole-branch review = Fable（controller本体）/ コード記述 = Sonnet subagent / 決定論的コマンド実行（build / test / xcodegen / xcodebuild / devicectl / gitのread系）= Haiku subagent / task review = Sonnet / 小さなfix再review = Haiku。subagent dispatch時はmodelを必ず明示する
- 実装は`superpowers:subagent-driven-development`で進める。ledger: `.superpowers/sdd/<plan名>/progress.md`（git管理外）。spec: `docs/superpowers/specs/`、plan: `docs/superpowers/plans/`
- 署名: Apple Development証明書が失効中のため、daemon / mac appはad-hoc署名（詳細と復旧手順はHANDOFF.md）。失効証明書で署名しない
- commit messageの末尾にCo-Authored-By / Claude-Session trailerを付ける
