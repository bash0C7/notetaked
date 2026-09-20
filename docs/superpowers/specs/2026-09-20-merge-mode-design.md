# 後がけmergeモード design（issue #4）

## 背景

issue #4はペアリングコード方式（今すぐ繋ぐ、TLS PSK+Bonjour）の代替として「同じiCloudアカウント等で自動的に相互識別したい」という要望から始まった。userとの検討（2026-09-20）で、これとは独立した第二の選択肢として「後から収録したデータをmergeするモード」が提案された。当初は各機材（Mac / iPhone / Watch / 別Macなど）が単体で独立収録し後で持ち寄る案として構想したが、調査の結果iPhone/Watchは現状standaloneで`timed.jsonl`/`final.md`を生成する経路を持たない（後述「v1のMac限定について」）ため、v1は**複数のMac**（例: 別々の場所で別々にNotetakeを起動した2台のMac）間のmergeに絞る。

**user決定事項（2026-09-20）**:
- merge処理そのもの（statement照合・統合ロジック）は本人かどうかを問わない、汎用の仕組みとして設計する
- ただし自動検出（どのファイルを誰が持ち寄るか）のルートは、iCloud連携（本人所有の複数機材のみ）から着手する。他人同士のファイルを持ち寄るルートは将来の拡張として設計上は排除しないが、実装はしない
- 起動方法は自動検出が望ましい（手動でファイル/フォルダを都度指定する方式より使いやすい）
- 時刻の合致判定ルールは後述（Claudeの技術判断として、既存Reconcilerの許容度に委ねるゆるい判定を採用）
- **merge処理（候補検出・統合・manifest・UI/CLI）の実装はMac版のみでよい（2026-09-20追記）**: iPhone/Watchアプリ側に対応する機能は作らない

既存のiCloud pairing spec（`docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`）は「今すぐ繋ぐ」ためのTLS PSK鍵配布をiCloud経由にする案であり、本specの後がけmergeとは**別の選択肢として並走**する。どちらを実装するか、あるいは両方実装するかはplan段階で決める。

## v1のMac限定について（2026-09-20追記）

調査の結果、iPhone（`Apps/NotetakeMobile/`）・watchOS（`Apps/NotetakeWatch/`）はいずれも現状standaloneで`timed.jsonl`/`final.md`を生成する経路を持たない。`SessionStore`（`.timed.jsonl`/`.final.md`/`.speakers.json`を書く唯一の型、`Sources/NotetakeCore/Session/SessionStore.swift`）はMacの`ServeSession`（`Sources/notetaked/Pipeline/ServeSession.swift`）からしかインスタンス化されない。iPhoneは`Outbox`（`Sources/NotetakeCore/Peer/Outbox.swift`）へ発話segを溜めるのみ（Mac接続を前提とした配信待ちqueueであり、render済みtranscriptではない）、Watchはローカルtranscript保持を一切持たずiPhone経由でしかsegを生成しない。

このため「各機材が単体で独立収録」という当初の想定はiPhone/Watchには現状当てはまらず、v1のmerge対象はMac上の`SessionStore`が生成した`timed.jsonl`同士（＝複数のMacインスタンス）に限る。iPhone/Watchを独立ソースとしてmergeに含める場合は、まず両アプリにstandalone transcript生成機能を作る別issueが前提になる（本specのスコープ外）。

## スコープ

- v1: 同一iCloudアカウントに属する本人の複数Mac間のみ。iPhone/Watch単体収録、他人の機材との統合は対象外（処理ロジックは排除しないが、発見・信頼の仕組みは作らない）
- v1: `timed.jsonl`（テキストレベルの発話データ）のみを同期対象とする。生音声（raw）はサイズが大きく同期コストが高いため対象外。将来必要になれば別途検討
- v1: 話者registryの機材間統合（他機材のSpeakerRegistryとの突き合わせ）はスコープ外。各機材が確定させた`speaker.global`ラベルをそのまま使う（同一人物が機材ごとに別ラベルになる可能性は残るが、既存のPeerClient経由の統合でも同じ制約がある）

## アーキテクチャ

### 1. 各Macのエクスポート

収録停止（`stop`）時、既存の`final.md`/`timed.jsonl`書き出しに加えて、`timed.jsonl`を**iCloud Drive上の共有フォルダ**（ubiquity container、`docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`が前提とする仕組みを流用）へコピーする。ファイル名はMac識別子とprefixを含める（例: `<device-id>_<prefix>.timed.jsonl`）。生音声は含めない。この処理はMacの`notetaked`/`Notetake.app`のみに実装する（iPhone/Watchアプリは変更しない）。

### 2. 候補検出（自動）

共有フォルダの変更（`NSMetadataQuery`等でiCloud Drive変更を監視、あるいはmenubar appの定期scan）をトリガに、以下を行う:

1. 共有フォルダ内の全`*.timed.jsonl`を読み、各ファイルの時間範囲（先頭utteranceの`start`〜末尾utteranceの`end`、wall-clock）を求める
2. 時間範囲が**少しでも重なっている**ファイル同士を同一候補groupとする（厳密な重なり率や最小重なり時間の閾値は設けない）
3. 既にmerge済みの組み合わせは、idempotency用のmanifest（後述）で除外する

**時刻合致ルールの根拠（Claudeの技術判断、2026-09-20）**: 候補検出を厳しくする意味は薄い。実際の統合可否は次段の`Reconciler`が担うため、候補検出はゆるく（false positiveを許容し、false negativeを避ける）設計する。無関係な収録が誤って候補になっても、Reconcilerがほぼ何も統合結果を出さず実害が無い。逆に候補検出を厳しくして本来統合すべき組を取りこぼす方が実害が大きい。

**時刻の基準**: 各Macのwall-clock（NTP同期前提）をそのまま使う。音声波形の相互相関によるオフセット推定は既存のPeerClientのping/pong方式でしか実装されておらず、後がけmergeでは接続実績が無いため使えない。後がけmergeは接続済みリアルタイム経路と違いクロック補正の手段が無く、Mac間のwall-clockずれがある程度大きくても実用になるよう、統合窓（次段）は現行のリアルタイム経路より広く取る（後述）。

### 3. 統合処理

候補groupごとに:

1. 各ファイルを`NDJSON.decodeAll`でデコード（resume機能で使っているものと同じ）
2. 全utteranceを時系列にマージしつつ`Reconciler.apply(_:)`へ順次投入。ただしmerge mode専用の`Reconciler.Config`（`toleranceMS: 5_000`、既定の`textThreshold: 0.5`は維持）を渡す — 現行のリアルタイム経路（ping/pongでクロック補正済み、`Config()`既定の`toleranceMS: 1_000`）とは別インスタンスで、既存の使用者向けリアルタイム統合の挙動には影響しない。同一device同士は統合しない既存ガードも維持
3. 統合結果から新しい`<merged-prefix>.final.md`・`<merged-prefix>.timed.jsonl`を生成する。元の各Macファイルは変更しない（追加のみ、非破壊）

### 4. Idempotency

`~/Library/Application Support/Notetake/merged/manifest.json`（案）に、どのソースファイルの組み合わせを既にmergeしたかを記録する。既存の`received/<device>.cursor`パターン（peer seg受信の冪等性）に倣う。再scanで同じ組み合わせを二重にmergeしない。

### 5. 起動経路

- 自動: menubar app（Notetake.app）がiCloud Drive共有フォルダの変更を監視し、バックグラウンドでmerge scanを実行
- 手動確認用: `notetaked merge --scan <dir>`（CLI、検証・デバッグ用。app無しでも動作確認できるようにする）

## 未決定事項（spec self-review時点、plan段階までに決める）

- iCloud Driveのubiquity container識別子・共有フォルダの正確なパス構造
- merge結果をuserに提示してから確定するか（プレビュー→承認）、完全自動で確定するか
- 話者registryの機材間統合（v1スコープ外だが、将来issueとして起票するか）
- iCloud pairing spec（今すぐ繋ぐ）との関係: 両方実装するか、片方を優先するか

## 関連

- issue #4: https://github.com/bash0C7/notetaked/issues/4
- 既存iCloud pairing spec（今すぐ繋ぐ案）: `docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`
- 既存の統合ロジック: `Sources/NotetakeCore/Reconcile/Reconciler.swift`（`Reconciler.apply(_:)`、既定`Config()`は±1秒・Dice 0.5。merge modeは専用`Config(toleranceMS: 5_000)`を使う）
- 既存のfold機構: `NDJSON.decodeAll`（resume機能、`ServeSession.resumeIfNeeded()`で使用）
- 既存の冪等性パターン: `~/Library/Application Support/Notetake/received/<device>.cursor`
