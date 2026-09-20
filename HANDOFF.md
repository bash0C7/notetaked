# HANDOFF — Notetake / notetaked

## 状態（2026-09-13）

- **M0〜M2完了、`main`にmerge済み**（`fa3bc8d`）。Mac単体の製品として動く（メニューバーapp + daemon、mic + system音声のリアルタイム文字起こし、`<prefix>.live.txt / .timed.jsonl / .final.md`、ライブパネル）
- **`main`にmerge済み（2026-09-14、fast-forward、PR #1）**。区切る + M3〜M6 + 段階L + 検証是正: 「区切る」機能 + M3〜M6を実装済み。Macで`swift build` / `make app`が通り、Notetake.app（新daemon同梱）が起動・userが動作OKを確認済み**（2026-09-13）。**`make verify`通過**（2026-09-13: `swift build`警告ゼロ / テスト164件 / mac app / iOS + watchOSコンパイル）。下記「Mac側で行う検証」のうちCLIで自動化できる分は合格（次々項）、人の操作が要る分は未実施
- **段階L（場所情報・対話整形）実装済み・`make verify`通過**（2026-09-13）。segの`input`/`direction`、`LocationLabel`、`DirectionEstimator`、iPhone `AVCaptureSession`+FOA、状態行/パネルの場所表示、polishの時刻無し対話出力。iPhoneの実機検証（`input.spatial`の値、方位、FOA変換のチャンネル順）は証明書再発行後。spec `docs/superpowers/specs/2026-09-13-spatial-location-polish-design.md`、plan `docs/superpowers/plans/2026-09-13-spatial-location-polish.md`。段階LのMac側検証で見つかった問題の全件・根本原因・是正はspec `docs/superpowers/specs/2026-09-13-stage-l-verification-remediation-design.md`、plan `docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md`。web側のledger（`.superpowers/sdd/2026-09-13-spatial-location-polish/`）はMacからは読めない。Mac側のledgerは`.superpowers/sdd/2026-09-13-stage-l-verification-remediation/progress.md`（git管理外）
- **Mac側CLI検証の結果（2026-09-13、`say`とsystem音声で自動実行）**: 段階1-1（rotateで2 prefix、status 4件、`rotated`ログ）合格。段階2-1〜2-3前半（`diarizer ready`、segに`speaker`（`g1`/`g2`が交互）、`<prefix>.speakers.json`、final.mdに`**g1**`/`**g2**`）合格。段階3-1（`polish: chunk 1/1`、`<prefix>.polished.md`）合格。段階4-1（`dns-sd -B _notetake._tcp`に`ゆふのMacBook Air M3`、ペアリングコードは設定Windowの値）合格。段階6-1のうち状態行（`input_name: "MacBook Airのマイク"`, `input_spatial: false`）とsystem segの`input`、final.mdの`（system）`は合格。段階6-3（`# 2026-09-13 リモート` / `# 2026-09-13 g1、g2`、時刻無し）合格
- **実機の環境（2026-09-13）**: Apple Development証明書は**再発行済み**（`security find-identity -v -p codesigning`で有効なidentity `A3F23595F28DC4E18B5063DF519E424A44778AB4`。失効した3本もkeychainに残っている）。iPhone 16e（`FE7B47C9-2CF0-5509-A52C-1C0D806CC085`、有線）へは`xcodebuild -scheme NotetakeMobile -destination 'id=<udid>' -allowProvisioningUpdates build` → `xcrun devicectl device install app --device <udid> .build/DerivedData/Build/Products/Debug-iphoneos/NotetakeMobile.app` → `xcrun devicectl device process launch --device <udid> io.github.bash0c7.notetake.ios`。無料developer profileは1端末3 appまで（Torchを削除して空けた。残りはStackchan / PicoRubyRunner）。段階6-1のmic segはuserの発話で合格（スピーカー経由の`say`は内蔵マイクで−60dBFSにしかならず認識されない）。iPhone 13 Proは対象外（user決定）
- **iPhone実機の結果（2026-09-13、iPhone 16e、Torchを削除して空きを作りインストール）**: 段階4-1〜4-4合格（Bonjour発見 → TLS PSK接続 → `hello`で`"t":"device"`（`offset_ms` 9）→ iPhone segがMacの`timed.jsonl`に入りfinal.mdで`**私**（iPhone 12時）:`）。段階6-4: **iPhone 16eは`input.spatial: true`**、FOA bufferは`4 ch, 48000 Hz, Float32, interleaved`。当初は`foaBuffer(from:)`の変換先formatが作れず（3ch以上はlayout必須）音声が届かなかったが、`foaChannels(from:)`で直接W / Y / Xを取り出す形に直して解決（是正spec項目9）。方位は平置きで話者位置を変えても0°付近に固まる → **軸の対応の校正はissue #2**（https://github.com/bash0C7/notetaked/issues/2、優先度低）。接続確認の手順: Mac側は`netstat -anv | grep <port>`（`lsof -p`はIPv6リンクローカルの接続を出さない）、iPhone側は`xcrun devicectl device process launch --console --terminate-existing --device <id> io.github.bash0c7.notetake.ios`でstderrの`peer client:` / `recorder:`行を読む
- **実機・UI検証の結果（2026-09-13夜、Macの操作はSystem Eventsで自動化: `osascript`でメニューバー項目・設定Windowの欄・パネルの話者ボタンを操作し`screencapture`で画面確認）**: 段階1-2（区切った瞬間にパネルが空になり状態行のprefixが変わる、2組のfinal.md）/ 1-3（0.05→「次の区切り」表示→23:14:19と23:17:22に自動区切り→0で表示が消える→24で復帰。欄への入力はAXの`focused`+`value`+Enterで通る。`click`+`keystroke`では入らない）/ 1-4（名前欄にfocusしたまま閉じても値が残りdaemonが新`--owner`で再起動）/ 2-3前半（パネルで`g1`→`Kyoko`、以後の行と大域`speakers.json`に反映）/ 3-2（メニュー「直前の収録を整形」→「整形完了: …polished.md」）/ 4-5（機内モード中のiPhone segが再接続後に`appended peer seg to <prefix>, final.md regenerated`で追記され、Macマイクの同じ発話と1行に統合。orphans無し）/ 4-6（iPhone再起動→再接続で`appended`は増えずcursorは6のまま。ack済みsegの強制再送は起きないため「再接続で二重化しない」の確認に留まる）/ 6-2（AirPods Pro 3を既定入力にして区切る→segの`input.name`が`ゆふAirPods Pro 3`、行が`（AirPods）`。外すと既定入力は内蔵マイクへ自動で戻り、次の区切りから`MacBook Airのマイク`）合格。2-4の参考値: 分離ありの遅延（`received_at`−`end`）は5〜16秒。2-5はスピーカー経由の`say`ではmicの認識が安定せず判定不能
- **不合格・クラッシュ（2026-09-13夜）→ 修正済み・実機で再確認済み（2026-09-14、plan `docs/superpowers/plans/2026-09-13-device-verification-fixes.md`、`make verify`通過168テスト）**: (a)は`ProfileNameAnnouncer`（global idのcapture初出時にprofile名を`SpeakerNameRecord`として流す。`rename_speaker`は`markAnnounced`で二重化を防ぐ）→ app再起動後の`say Kyoko`が`**Kyoko**（system）`。(b)はtap closureに`@Sendable`明示→Watchで録音・20秒小片→iPhone `WatchRelay`→Macに`platform: watchos / source: watch`のsegが届き、final.mdで`**私**（Watch）:`としてMacマイクと統合（停止後到着分は`appended peer seg`で追記）。(c)は`Diag.log`→console切断後にMac appを再起動（peer切断・再接続）してもiPhone appは生存。以下は当時の分析: (a) 段階2-3後半: app再起動後、同じ声は`SpeakerRegistry`で`Kyoko`と一致する（cos 0.93、`<prefix>.speakers.json`にも`name`が入る）のに行は`**g1**`。`ServeSession.handleFinal`が`registry.name(for:)`を引かず、表示名を決める`Reconciler.speakerNames`は`rename_speaker`でしか埋まらない（`startCapture`ごとに新規）。案: global id初出時にregistryに名前があれば`renameSpeaker`と同じ経路（`SpeakerNameRecord`追記→`reconciler.apply(.speakerName)`、大域保存無し）を通す (b) Watch app: 「開始」直後にクラッシュ（`NotetakeWatch-2026-09-13-233416.ips`、`EXC_BREAKPOINT`、audio threadの`RealtimeMessenger.mServiceQueue`、`closure #1 in WatchRecorder.start()`）。`AVAudioNodeTapBlock`は`@Sendable`でないため`@MainActor`クラス内のclosureがMainActor隔離と推論され、real-time threadからの呼び出しでexecutor検査に落ちる。案: `installTap`のclosureを`{ @Sendable buffer, _ in … }`と明示 (c) iPhone app: devicectlのconsoleが切れた後の`PeerClient.state.didSet`で`FileHandle.standardError.write`が`NSFileHandle`例外→`SIGABRT`（`NotetakeMobile-2026-09-13-233335.ips`）。35e3fa4で入れた診断出力（Recorder 10 / PeerClient 3 / WatchRelay 4箇所）が原因。案: `Diag.log(_:)`（`os.Logger`+`fputs(stderr)`、初回に`signal(SIGPIPE, SIG_IGN)`）へ置換。crash logの取り方: `xcrun devicectl device copy from --device <iPhone> --domain-type systemCrashLogs --source . --destination <dir>`（Watchのcrash logもiPhoneの`ProxiedDevice-*/`配下に同期される。Watchへの直接トンネルは`--console`も`copy`もタイムアウトしやすい）
- **気づき**: issue #7 / #8 / #3に転記済み
- **人の操作が要る残り**: なし（2-4・2-5はuser判断事項として残るが検証は完了扱い）
- **実機検証はuser宣言で完了（2026-09-14）。後回しの要望と気づきはissue化済み（優先順位は未定、userの指示で今は付けない）**: #3 ライブパネルのtoolbar overflow（ハンバーガー位置） / #4 ペアリングコード廃止・iCloud識別 / #5 Macセッション開始とiPhone取り込み開始の概念整理 / #6 場所ラベルは`level_dbfs`最大のsegの機器（決定済み） / #7 daemon再起動後のiPhone「接続」表示とCLOSE_WAIT / #8 分離結果の無い短い発話が所有者名に割れる / #2 方位の軸校正 / #10 `make verify`がxcodebuildのスキームレベル失敗（watchOSランタイム未導入など）を検出せず`verify: OK`を出す（別セッションからの報告、未再現） / #11 iPhone `PeerClient`が`.waiting`を無視しネットワーク変更後「接続中」のまま復帰しない。「接続中」がconnecting / connectedのどちらか読めない表示も併せて直す / #12 ツール名は`notetaked`、読みは「のたてけでぃー」（語源: notetake = 速記 + daemon）をREADMEに記載
- **issue #13 / #14 / #10 / #11 実装済み・未検証（2026-09-16、Claude Code on the web、Linux）**: このセッションはSwiftツールチェーンが無く`make verify`・実機確認ができないため、コード変更のみでMac側の検証が未実施。plan: `docs/superpowers/plans/2026-09-15-control-responsiveness-and-reliability-fixes.md`
  - #13: `CaptureStream.ingest`が`diarizer.feed`を直接awaitしていたのをchained `Task.detached`へ逃がし（`diarizerChain`）、`finishAfterFlush`でのchain完了待ち・`diarizer.flush()`それぞれに5秒の上限を設けた（`Sources/notetaked/Pipeline/CaptureStream.swift`）。stop/rotateが無期限にハングしなくなるが、issue本文の「24時間運用でのバックログ・メモリ推移」「データロス防止（プロセス分離等）」は未対応のままissueに残す。`stopCapture()`がstreams（mic/system）を順に`stop()`しているため、両方が同時にbacklogを抱えていると最悪合計約20秒待つ（並列化は未対応）。→ 24時間規模のバックログ計測はissue #9で確認した約6.5時間の安定運転で十分とし対応不要と判断（2026-09-17、user決定）。データロス防止（プロセス分離）はissue #15として切り出し済み
  - #14: `MicCapture`が`AVAudioEngineConfigurationChangeNotification`を購読しtapを張り直す（`Sources/notetaked/Audio/MicCapture.swift`）。`ServeSession.startCapture`のconsumer Taskがmicの`input`を毎回`InputDeviceProbe.current()`で取り直すよう変更（`Sources/notetaked/Pipeline/ServeSession.swift`）。issue本文の項目1（自動追随）のみ対応。項目2（明示的デバイス選択）・項目3（入力レベルのリアルタイム表示）は未対応のままissueに残す
  - #10: `Makefile`の`verify`ターゲットの各ステップに`; test ${PIPESTATUS[0]} -eq 0`を追加。ただしsubagentの自己レビューで、`.SHELLFLAGS := -eo pipefail -c`が効いていればこのチェックは元々冗長（pipefailだけで同じ行が失敗する）と判明。issue本文の症状（`make verify`のshell exit code自体が0だった）はxcodebuild自身が「error:」を出しつつ真にexit 0を返した可能性が高く、PIPESTATUSチェックだけでは再現しても検出できない。そのため`app`/`ios`両ステップのログに`^xcodebuild: error:`（issue本文のエラー文と同じprefix）が無いことを見る`XCODEBUILD_ERROR`grepを追加した（`! grep -E $(XCODEBUILD_ERROR) ...`）。再現（watchOS Simulatorランタイム未導入等）はこのセッションでは実施できず、ロジックレビューのみ
  - #11: `PeerClient`が`.waiting`を3回連続観測したら`.failed`と同様`handleDisconnect`を呼ぶようにした（`Apps/NotetakeMobile/PeerClient.swift`）。`ContentView.peerStatusText`を「接続試行中: <名前>」「接続済み: <名前>」に変えconnecting/connectedを読み分けられるようにした
  - **Mac側実機検証の結果、#13/#10 close済み（2026-09-16）**: #13は`say -v Kyoko`/`say -v Otoya`で2話者音声を再生しdiarizerに負荷をかけた状態で「区切る」約1.5秒・「収録停止」約2.2秒で反映、ハング解消を確認。ただし本文後半の追記2件（24時間規模のバックログ計測、データロス防止のプロセス分離）は未対応のままissueに残さずclose時のコメントで明記。#10はwatchOS Simulatorランタイム未導入の状態で`xcodebuild`がexit 0のまま`xcodebuild: error:`を出す状況を再現し、追加した`XCODEBUILD_ERROR`grepが`make verify`を正しく非0で止めることを確認。#14（AirPods抜き差し）・#11（Wi-Fi切替）はこのMac側セッションにiPhone実機が物理接続されておらず未検証のまま持ち越し
  - **#13の残課題を仕分け（2026-09-17、user決定）**: 24時間規模のバックログ計測は不要（issue #9で確認した約6.5時間の連続運転が安定していたため）。データロス防止（音声取り込み/認識と制御コマンド処理のプロセス分離）は気になるとのことでissue化: https://github.com/bash0C7/notetaked/issues/15
- **issue #7 / #8 / #6 / #3 / #5 実装済み・未検証、#4は検討のみ（コード変更なし）（2026-09-16、Claude Code on the web、Linux）**: このセッションはSwiftツールチェーンが無く`make verify`・実機確認ができないため、コード変更のみでMac側の検証が未実施。plan: `docs/superpowers/plans/2026-09-16-remaining-issue-fixes.md`
  - #7: `PeerListener.handleDisconnect`が`connections`から外すだけで`NWConnection.cancel()`を呼んでいなかったのを修正し、相手がFINを送った後にCLOSE_WAITが残らないようにした（`Sources/notetaked/Peer/PeerListener.swift`）。`PeerClient`には受信監視watchdogを追加（`Apps/NotetakeMobile/PeerClient.swift`）: Macが接続中60秒毎に送り続けている既存pingを含め、何か受信するたびに`lastActivityAt`を更新し、150秒（ping間隔の2.5倍）無通信なら`.failed`同様`handleDisconnect`→再browsingする。issue本文はPeerClient発のping送信を提案しているが、Macの既存pingの受信監視で同じ目的を達成する形に変えた（往復メッセージを増やさない）
  - #8: `Reconciler`で分離結果が間に合わず`speaker`が付かないsegについて、同じ`device`の直前のutteranceの`speakerID`を、時間差5秒以内なら継承するようにした（`inheritedSpeakerID`、`Sources/NotetakeCore/Reconcile/Reconciler.swift`）。継承元が無い（そのdeviceの最初の発話）か5秒を超える間隔ではownerLabelにfallbackする現状のまま
  - #6: `Utterance`に場所ラベル専用の`locationInput`/`locationPlatform`/`locationSource`/`locationDirection`/`locationLevelDBFS`を追加し、統合したsegのうち`level_dbfs`が最大のものに更新するようにした（`merge`）。既存の`input`/`platform`/`source`/`direction`（本文の勝者・confidence基準のdirection）はそのまま。`LocationLabel.text(for:)`だけを新フィールド参照に変えた（`Sources/NotetakeCore/Model/Utterance.swift`、`Sources/NotetakeCore/Reconcile/Reconciler.swift`、`Sources/NotetakeCore/Render/LocationLabel.swift`）。`Utterance`のmemberwise init変更に伴い、`MessagesTests.swift`/`PolishChunkerTests.swift`/`TranscriptRendererTests.swift`の`Utterance(...)`呼び出し箇所も追随させた
  - #3: `LivePanelView`の操作ボタン（収録開始/収録停止/区切る/整形/常に前面/全文コピー）を`.toolbar`から本文上部の横スクロール可能な行へ移し、`.toolbar`にはステータス文言だけ残した（issue本文の案2）（`Apps/Notetake/LivePanelView.swift`）
  - #5: Mac側のボタン・状態文言を「セッション開始」「セッション終了」「セッション中」「セッション無し」に、iPhone側を「取り込み開始」「取り込み中（タップで終了）」・セクション見出し「取り込み」に変え、iPhone側に「Macでセッションを開始してから使う」旨の説明文を足した（`Apps/Notetake/LivePanelView.swift`、`Apps/NotetakeMobile/ContentView.swift`）。**残課題**: `Apps/Notetake/MenuContent.swift`（メニューバーメニュー）は同じ`appModel.startRecording()`/`stopRecording()`に対して依然「収録開始」「収録停止」のままで、ライブパネルの「セッション開始」と文言が食い違う。`.claude/skills/mac-app/SKILL.md`の`ntmenu.sh`自動操作がこの文字列に依存しているため、今回は変更を見送った（変更する場合はskillの文字列も合わせて直し、Mac側で自動操作が通るか確認すること）。Macの現在prefixをiPhoneへ伝えるプロトコル変更（iPhone側に「Macのセッション: <prefix>」と出す）はスコープ外のままissueに残す
  - #4: コード変更なし。ペアリングコード方式の代替はCloudKit案・`NSUbiquitousKeyValueStore`案を比較し、後者（既存のBonjour+TLS PSK経路は残し鍵配布だけをiCloud経由にする）を推奨として`docs/superpowers/specs/2026-09-16-icloud-pairing-design.md`にまとめた。iCloudアカウント・entitlement操作の実機検証が前提のため実装はしていない
  - **Mac側実機検証の結果、#3 close済み・#5はMac側のみ確認（2026-09-16）**: #3はwindow幅480pxまで狭めてボタン行が横スクロールで使え`.toolbar`にはステータス文言のみ残ることを確認。#5はMac側のボタン・状態文言（「セッション開始/終了」「セッション無し」等）は確認したがiPhone側（「取り込み開始/中」）はiPhone実機未接続のため未検証、issueはopenのまま。#7（daemon再起動後の自動再接続・CLOSE_WAIT）、#8（短い相槌の話者分裂）、#6（場所ラベルの機器切り替え）はいずれもiPhone/AirPods等の物理操作が要り、このMac側セッションでは未検証のまま持ち越し
  - **`make verify`で1件ビルド失敗→修正・反映済み（2026-09-16、Mac実機で発見、このLinuxセッションでdiffを受け取り適用）**: `ServeSession.swift`の三項演算子がクロージャを構築する式（`source == .system ? { .system } : { InputDeviceProbe.current() }`）でswift-frontendが内部エラー（`failed to produce diagnostic for expression`）を起こしたため、if/elseで同じ`@Sendable`クロージャを組み立てる形に書き換えて回避（挙動は変えていない）。Mac側セッションのローカルcommit（`aa927ee`）は未push・別containerのため、このLinuxセッションでは同内容を別commitとして直接適用してpush
- **issue #9 実機検証済み・close（2026-09-16、Mac実機、約6.5時間の連続運転）**: `--source both`+分離あり+iPhone/Watch peer接続ありの状態で`ps`ベースのメモリ推移を長時間観測。`notetaked`（daemon）は130MB→92〜101MBの範囲で終始横ばい〜微減、増加傾向なし。Notetake.app（メニューバーapp）は205MB→228MBまで緩やかに増えたあと163MBへ大きく落ち、以後170MB前後で安定（単調増加ではなく「増えて減る」波を1回観測）。CPUは全時間帯で瞬間値のみでスパイク張り付き無し、プロセス落ちも無し。daemon側は明確に安定と言える。app側は1波のみの観測のためOSの通常のメモリ管理（未使用ページ解放）か特定イベントに連動した解放かは未切り分けで、「リークではない」とは言えるが「あらゆる条件下で安定」とまでは言い切れない。issue本文が求めた24時間運用に対しては今回の約6.5時間・1波のデータは部分的な裏付けにとどまる（再発したら再度計測・issue再オープン）
- **PR #16の実機検証、#7 #11 #5 #6 #14 close済み・#8は不発（2026-09-18〜19、Mac実機+iPhone 16e無線接続+AirPods Pro 3実機接続）**: `make verify`通過（171テスト、警告ゼロ）後に実施
  - #13（再検証）: チャンク未feedのまま開始→即停止しても偽のdiarizer backlog警告が出ないことを確認（回帰無し）
  - #8: `say`合成音声では分離処理のレース条件（短い相槌が分離結果の間に合わない状況）を意図的に再現できず、実機的な検証は不発。誤マージ・クラッシュ等の異常は無し。継承ロジック自体はユニットテストで担保済みのため、issueはopenのまま次回実際の会話で確認
  - #7 close: daemon（Notetake.app）再起動（peer listenerポートが54098→54099に変わる＝旧プロセス完全終了）から5秒以内にiPhoneが自動再接続。旧ポートにCLOSE_WAIT残留無し
  - #11 close: iPhoneのWi-Fiオフから約60秒でMac側が切断検知（メニュー表示消失、ソケットもクリーンに消滅）、Wi-Fiオンから10秒以内に自動再接続
  - #5 close: iPhone側「取り込み開始/取り込み中」表示をuser目視確認、違和感なし
  - #6 close（2026-09-19）: AirPods Pro 3実機接続。AirPods経由の発話は final.md で「（AirPods）」、内蔵マイク経由の発話は「（Mac）」と場所ラベルが正しく切り替わる。同一収録セッション内で機器を跨いでも正しく振り分けられた
  - #14 close（2026-09-19）: 収録継続中（「区切る」を挟まず）に既定入力をAirPods→内蔵マイクへ切り替えたところ、次の発話segのinput.nameが自動的に`ゆふAirPods Pro 3`→`MacBook Airのマイク`へ追随。クラッシュ・認識停止等の異常無し
  - **わかったこと**: iPhoneがロックされているとdevicectlでの起動自体が`FBSOpenApplicationErrorDomain error 7 (Locked)`で拒否され、backgroundサスペンドでwatchdog/reconnectの検証が不可能になる。無線devicectl consoleトンネルは不安定（数十秒で切れる、`connection was invalidated`／`device disconnected immediately after connecting`が散発）。実機再接続テストはiPhoneの画面ロック解除＋Wi-Fi物理操作がuser依存（devicectlにUI tap/screenshot機能が無いため）。AirPodsのBluetooth接続確立もSystem Events経由の自動化を試みたが安定せず断念、物理操作が必要
- **入力デバイス明示選択機能を実装・実機検証済み（2026-09-19、AirPods Pro 3実機）**: user発案（会話中のbrainstorming、issue番号無し）。ライブパネルに「入力デバイス」Picker（既定/特定デバイス）を追加、選択したデバイスへ固定（pin）し、pin先が切断されたら録音を止めずに自動でOS既定へフォールバック・Pickerの表示も「既定」に戻る（前回pinしていたデバイスは覚えない、user決定）。デバイス選択欄はSettings WindowでなくLivePanelViewに置く（user指定: 「デバイス選択はライブパネルのみに置いてほしい」）
  - **実装の経緯（systematic-debuggingで根本原因を特定）**: 当初`AVAudioEngine.inputNode`へ`kAudioOutputUnitProperty_CurrentDevice`を直接設定する方式で実装したが、実機（AirPods Pro 3）で(a)`installTap`時に`format.sampleRate == inputHWFormat.sampleRate`のassertionでクラッシュ（`AudioUnitSetProperty`直後は`outputFormat(forBus:)`がハードウェアformatへ未追従）、(b)クラッシュを避けても無音（`CaptureStream`の`AudioConverter`が`init`時に固定formatで構築されるため、pin適用のタイミング次第で誤formatのまま毎回黙って変換失敗）の2系統の不具合が出た。4回の修正（`reset()`→`Uninitialize`/`Initialize`→通知ガード→pin適用をinit()へ前倒し）を重ねても解決せず、Web調査で同種の問題が他の開発者の間でも「どの対策も効かない」既知の制約と判明したため、Technical Note TN2091（生のAUHAL AudioUnit、AVAudioEngineを介さない）方式へ全面的に書き換えた（`AUHALPinnedCapture`、`Sources/notetaked/Audio/MicCapture.swift`）。TN2091の正式な記述（デバイス実formatはinput scope element 1、client formatはoutput scope element 1にset）に沿って、当初の実装がoutput scopeを何もsetせずgetしていた誤りも修正。pin無し（既定入力追随、issue #14）の経路は無変更
  - **実機検証結果**: CLI（`--input-device <uid>`）・mac app（ライブパネルのPicker）の両方でAirPods pin経由の発話認識を確認（`input.uid`がAirPodsのUID、`input.name: "ゆふAirPods Pro 3"`で正しくsegに記録）。pin先切断時のフォールバックも、一時的なdebugログ（`reinstallTap`の`engine.start()`結果）を仕込んだCLIテストで`engine.start()`成功・`isRunning=true`・有効なformat取得・`.input_reset`イベント送出まで一連の流れを確認（該当debugログはcommit前に削除済み）。mac app UIでの初回確認時は新しい発話が反映されず見えたが、これは観測タイミングの問題（CLIでの再現テストでは正常動作）と判断
- **issue #15（データロス防止のプロセス分離）実装・`make verify`通過、実機検証は未実施（2026-09-19、`superpowers:subagent-driven-development`で12task自律実行、worktree `.claude/worktrees/capture-process-separation`）**: `notetaked capture-daemon`（新設・マイク/システム音声のtapのみ、軽量・常駐）と`notetaked serve`（既存、話者分離/文字起こし/出力/制御）の2プロセスに分離。生音声はOS tmp（`notetake-capture/<prefix>/`、自己記述フレーム形式、切り詰め・削除ロジック無し=削除はOS任せ）へ`capture-daemon`が追記し続け、`process`側は`RawAudioReaderCapture`（`AudioCapture`プロトコル準拠）でtail読みする。`process`はfinalな発話確定ごとに`<source>.checkpoint`（byte offset、アトミック書き込み）を更新し、再起動時はこのcheckpointから再開する（`ServeSession.resumeIfNeeded()`、`~/Library/Application Support/Notetake/state/current-session.json`の再開マーカー経由）。両プロセスは同ディレクトリ配下の固定パスへ5秒ごとに心拍ファイルを書き、メニューバーapp（`CaptureDaemonSupervisor`）が15秒無更新でハングとみなしgraceful（SIGTERM+5秒猶予）→forced（SIGKILL）で再起動する。`process`↔`capture`間の制御（セッション開始/終了・pinデバイス切断時のフォールバック通知）はsocket/FIFOではなく、checkpointと同じ「アトミックファイル書き込み＋ポーリング」パターンの`CaptureControlChannel`で行う（spec段階でstdio想定だったが、両プロセスがメニューバーappの個別の子プロセス=兄弟関係でstdio直結できないため設計変更、実装時に判明）。spec: `docs/superpowers/specs/2026-09-19-capture-process-separation-design.md`、plan: `docs/superpowers/plans/2026-09-19-capture-process-separation.md`（12task、SDD ledgerは`.superpowers/sdd/2026-09-19-capture-process-separation/progress.md`、git管理外）
  - **`make verify`結果**: 202テスト全件通過、全target警告ゼロ、`verify: OK`
  - **実機検証が必要な項目（未実施）**: (1) `notetaked serve`を`kill -9`し、メニューバーappが自動再起動、checkpointから再開して欠落が最小限であることを確認 (2) `notetaked capture-daemon`を`kill -9`し、心拍staleを検知してメニューバーappが再起動することを確認 (3) 長時間セッション（数時間）でtmp領域の増加がOSの管理範囲内であることを確認 (4) AirPods等のpinデバイス切断時、`capture-daemon`から`process`への`inputFallback`イベント伝播が新アーキテクチャ下でも既存のフォールバック挙動（入力デバイス明示選択機能、上記）と同様に動くことを確認
  - **実装中に見つかった、当初specに無かった設計判断（記録）**: `ServeSession`の`inputAt`クロージャは、pin中のmic入力メタデータをこれまでの`MicCapture.currentInputDevice()`（同一プロセス内のライブ状態）ではなく`InputDeviceProbe.current()`（OS既定入力）から取る形に後退した——`MicCapture`が`capture-daemon`プロセス側に移り、`process`側から直接参照できなくなったため。pin中とOS既定が一致する通常時は影響無いが、pin中に両者が食い違う場合、segの`input`メタデータがOS既定入力を指す可能性がある（実際の発話認識・保存された音声には影響しない、表示メタデータのみの限定的な後退として実装時に許容）
  - **最終whole-branch review（opus、19commit・87KBのdiff）で5件のCritical findingを検出、うち4件を2回のfix wave（計3 commit、各scoped re-reviewで検証済み）で修正・`make verify`再通過（202テスト・警告ゼロ）**: 個別task単位のreviewでは検出できない、プロセス跨ぎの結合不具合だった
    - **修正済み（commit `9f976e4`）**: (a) ハングした`notetaked serve`を強制終了する経路が無く復旧が完結しない不具合 — `DaemonClient.terminate()`にSIGTERM→3秒猶予→SIGKILLの昇格を追加、ハング検知経路で`client`/`daemonRunning`を明示的にクリア (b) process heartbeatの書き込み開始が`Diarizer.prepareModels`等の後で、通常起動・resume起動が誤ってハング判定され再起動ループ→恒久停止に陥る不具合 — 起動直後に同期的にheartbeatを1回書き、メニューバーapp側にdaemon起動時刻起点の30秒猶予を追加 (c) `notetaked serve`再起動のたび、前回runの`.inputFallback`イベントが再生され、pin中デバイスが何も起きていないのに恒久的に解除される不具合 — poll開始時に`lastCaptureEventSeenAt`を現在時刻へseed
    - **修正済み（commit `5c81b33`→`4763866`、2 round）**: (d) checkpointが「読み終えた位置」（reader先端、tail読みでほぼ実時間）を保存しており、話者分離・文字起こしの遅延（Aligner保留上限12秒、backlog時は無制限）ぶん常に先行していたため、crash/再起動のたびに「最後に確定した発話の終端〜checkpoint」の区間が二度と処理されず恒久的に失われていた（specの意図と正反対、この機能の存在理由そのものを損なう不具合）。修正: `RawAudioReaderCapture`に音声長ベースのring buffer（`offset(atOrBeforeAudioMS:)`）を追加し、`handleFinal`は`piece.endMS`に対応する位置をcheckpointするよう変更。round 1のreviewでring bufferの粒度がpoll batch単位だった欠陥（resume直後の一括backlog読みで同じ不具合が再現しうる）とms丸め誤差の線形driftを追加で発見・修正（round 2、frame単位のlogging＋整数sample数での累積に変更）。opusによる2回の独立reviewで、座標系の数学的根拠（`piece.endMS - originMS`と`cumulativeAudioMS`が同一の量であること）まで実コードを追って検証済み (e) resume時に`reconciler`/`seq`を無条件リセットしており、crash前のtranscript内容が`final.md`から失われていた（`timed.jsonl`には残るが描画されない）。修正: resume時に既存`timed.jsonl`を`NDJSON.decodeAll`→`Reconciler.apply`で畳み込み、`seq`を既存最大値から継続
    - **既知の残存課題（未修正・実機検証フェーズへ持ち越し、user判断待ち）**:
      1. **（Critical）pinデバイス切断後、formatの変わったframeが`RawAudioReaderCapture`で黙って永久に捨てられる** — `MicCapture`のreinstallTapは新formatで正しくtapし直すが、reader側は`init`時に決めたformatと一致しないframeを`continue`で無音扱いにし続ける。切断後その収録は音声を拾わなくなる（checkpointだけは進む）。実機でのAirPods等の抜き差しが要るため、上記(4)の実機検証と合わせて確認・対応すること
      2. **（Important）resume直後の再処理区間がReconcilerで重複除去されない** — 上記(d)の修正で「無制限の無言消失」は解消したが、`Reconciler.applySegment`のsame-device除外guard（cross-device統合専用）が同一device内の再処理utteranceを吸収しないため、crash直前の数秒〜十数秒分がfinal.mdに近い内容で二重に見える可能性がある。境界は動くが消失はしない
      3. **（Important）capture-daemon自身のcommand再生・`.error`イベント黙殺** — capture-daemonも`lastCommandSeenAt`を毎回nilから始めるため再起動時に直前commandを再生しうる（通常は収束するが特定のresume失敗と重なると停止できないphantom recordingが残り得る）。また`ServeSession.pollCaptureEvents`は`.inputFallback`以外（`.error`含む）を無視するため、capture起動失敗（TCC拒否等）はuserに伝わらず「recording: true」なのに無音、というだけになる
      4. **（Minor、複数）**: `CaptureControlChannel`の壁時計比較（NTP/手動時刻変更で影響を受けうる）、`send()`失敗時の一時ファイル残留、破損channelファイルの黙った無限停止、他にTask 2/6/9で既に記録済みの軽微項目
    - 詳細な議論・review全文の要旨・rulingはgit commit履歴（`docs(plan):`/`fix(capture):`系のcommit message）とこのHANDOFF記載を正とする。SDD ledger本体（`.superpowers/sdd/2026-09-19-capture-process-separation/progress.md`）は完了後に削除済み（git管理外・plan完了時の既定動作）
  - **PR #17作成済み**: https://github.com/bash0C7/notetaked/pull/17 （branch `worktree-capture-process-separation`、worktree`.claude/worktrees/capture-process-separation`に保持中）。mergeは実機検証完了までuserから切り出すまで話題にしない
  - **CLI駆動の実機検証、検証1〜3完了・合格（2026-09-20、`.claude/skills/daemon-realtest/SKILL.md`に沿って自律実行、worktree release binary、userの本番Notetake.appとは別binary・別directoryで並行稼働・干渉なし）**:
    - **検証1（`notetaked serve`のcrash→自動resume）合格**: capture-daemon起動→serve起動→`say`で発話→final確定確認後、serveを`kill -9`。crash直後もcapture-daemonのheartbeatは更新継続（影響なし）。crash中にも`say`で発話を追加。同じ`--output`でserveを`--start`無しで再起動→`resumeIfNeeded()`が同一prefixを自動再開（status eventで確認）。追加発話→SIGTERMで正常終了→`final.md`に**crash前後両方**のutteranceが残存、`timed.jsonl`のseqも1から継続（リセットされない）。C4修正（resume時のreconciler/final.md復元）が実機で機能することを確認。**注記**: 初回試行でcrash〜resume間隔を数分〜十数分空けてしまい、system.raw backlogが30分規模に膨らんだ結果、オンデバイスSpeech認識が実時間ペースでしか追いつかず5分待っても新規segmentが出ない事象に遭遇（バグではなくテスト設計ミスと判断、crash〜resumeを秒単位に縮めて再実行し解消）。認識文字列自体は`say`+system audio tap特有の断片化（「あ」「ち」「中」等の一文字認識）が見られたが、これはHANDOFF既知の合成音声認識精度の制約であり本feature の検証対象外
    - **検証2（`capture-daemon`のcrash→serveの耐性）合格**: 両プロセス稼働中にcapture-daemonを`kill -9`。serveは生存し続け、system.rawの成長が停止（新規音声を拾わなくなる＝想定通り）。capture-daemonを再起動すると、**serve側から何もコマンドを再送しなくても**system.rawの書き込みが自動的に再開（capture-daemon起動直後の`lastCommandSeenAt = nil`によるcommand-file再生が、既知の残存課題(3)「capture-daemon自身のcommand再生」を逆に自己修復として働かせている）。新しい発話も認識再開を確認
    - **検証3（tmp領域の増加）合格**: 検証1・2の実行中、`system.raw`が切り詰め無く線形に増加し続けることを確認（設計通り、OSのtmp管理に依存）
    - **CLI検証環境の技術メモ**: (a) worktree isolationのBash実行環境では複雑な複合コマンド（`&&`連結、長いpath中の`git`文字列を含むもの等）が「too complex to verify」で拒否される場合があるため、単純な1コマンド1操作に分割し、長いscratchpad pathはシンボリックリンクで短縮すると安定する (b) `notetaked serve`の`--control stdio`はstdinがEOFに達すると`quit`扱いで終了するため、crashテストで長時間プロセスを維持するにはstdinを閉じない工夫が要る（`tail -f /dev/null | notetaked serve ...`のように、書き込み側が閉じないパイプでstdinを繋ぐ） (c) `StdioControl`の`print()`はstdoutをファイルにリダイレクトするとフルバッファリングされ、`kill -9`で握り潰されたバッファ内容は失われる（正常終了時はflushされる）ため、events.logをリアルタイム検証の正とせず、`SessionStore`が直接`FileHandle.write`する`timed.jsonl`/`final.md`/checkpointファイルを一次情報源とすること
    - **GUI app本体でのheartbeat staleness→SIGTERM→SIGKILL昇格→自動再起動、合格（2026-09-20、user依頼不要・完全自律で実施）**: userの本番app（`io.github.bash0c7.notetake`）を一切触らず、`xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=io.github.bash0c7.notetake.realtest`で別bundle IDのthrowawayビルドを別`-derivedDataPath`（`/tmp`配下）に作成し、`defaults write io.github.bash0c7.notetake.realtest outputDirectory/ownerName`で独立したUserDefaults domainを設定してから単独起動（production appとは完全に別プロセス・別設定・別app実体）。起動した`notetaked serve`へ`kill -STOP`を送りハングを模擬（SIGTERM無視される停止状態）→ `process.heartbeat`の更新停止を確認 → 数十秒後、元PIDが消滅（SIGKILLでのみ停止中プロセスを終了できるため、これ自体がSIGKILL昇格が発生した証拠）→ 新しいPIDの`notetaked serve`が自動的に起動し、`process.heartbeat`が再び最新時刻に更新されることを確認。`AppModel`の監視ループ・`DaemonClient.terminate()`のSIGTERM→SIGKILL昇格・自動再起動が実機（実際のGUI appプロセス）で動作することを確認。終了後はtest app・throwawayビルド・独立UserDefaults domain・共有state/tmpファイルを全て削除、production appのプロセス（PID変更無し）を確認して無傷を確認済み
    - **C5（pinデバイスformat変化）、実機再現・確認済み（2026-09-20、userがAirPodsケースを開け近傍接続可能な状態にした後、以降は`blueutil`によるBluetooth接続制御のみで完全自律実行）**: 最初の試行（Built-in⇄iPhone Continuityマイクの切替）は両デバイスとも`AVAudioEngine`の`outputFormat(forBus:)`が48000Hz/1chに正規化されておりformat不一致が起きず不成立。根本原因を確認したところ、pin時は`AUHALPinnedCapture`（TN2091生AUHAL、`AVAudioEngine`を介さずデバイスの真のnative formatを使う）という別経路であることが判明。`--input-device CC-22-FE-79-98-E3:input`でAirPods Pro 3にpinして起動 → `system_profiler`で確認済みの実機ネイティブformat通り**24000Hz/1ch**でmic.rawへ書き込まれることを`dump_frames`診断ツールで確認 → `blueutil --disconnect CC:22:FE:79:98:E3`でBluetoothをソフトウェア切断（物理操作は最初の1回・case開放のみ、以降は無し）→ 期待通り`.input_reset`イベントが発火 → 切断後のframeは`dump_frames`で**48000Hz/1ch**（`AVAudioEngine`経由のfallback）に遷移していることを確認（frame 2171を境に24000Hz→48000Hz、実機・実イベントでのformat変化を直接証拠として確保）。`RawAudioReaderCapture`は`init`時に固定した24000Hzのformatのまま動作し続けるため、`guard frame.sampleRate == format.sampleRate ... else { continue }`により、fallback後に実際に取り込まれた48000Hzのframe（テスト終了時点で1648フレーム、実時間で数十秒〜1分規模の実音声）が永久にCaptureStreamへ渡らずdropされ続けることを、raw frameのformat遷移点とtimed.jsonlのsegment数（fallback前後を通じて終始0件のまま増えない）の両面から確認。`say`+AirPodsマイクの音響的ピックアップが弱く認識テキストそのものは得られなかったが、**dropの根拠は認識精度に依存しない構造的事実**（実際に書き込まれたframe数とそのformat）として確定。テスト後はAirPodsを`blueutil --connect`で再接続し元の状態に復元済み
- **issue #15、実機検証完了・PR #17をmain へno-ff merge・close済み（2026-09-20）**: 上記の実機検証（検証1〜3・SIGKILL昇格・C5）は全てClaudeが自律実行。C5（pinデバイス切断後のformat変化でframeが永久にdropされる不具合）は未修正のままissue #18として切り出し済み: https://github.com/bash0C7/notetaked/issues/18。作業用worktree（`.claude/worktrees/capture-process-separation`）・ローカル/リモートbranchは削除済み、この`HANDOFF.md`は再びmain checkout（`/Users/bash/dev/src/github.com/bash0C7/notetaked`）のもの
- **open issue #18・#8・#4・#2をまとめて対応・branch `followup-issue-18-8-4-2`でdraft PR作成（2026-09-20）**: `/compact`後、user指定通り4件を並行して着手（`main`直下に一旦4commit積んだ後、branchへ退避してdraft PR化。origin/mainへの直push・自動merge提案はしていない）。draft PR: https://github.com/bash0C7/notetaked/pull/19
  - **#18（pinデバイス切断後のframe drop）: 修正・実機検証済み（commit `b9c027b`）。issueはopenのまま（PRがmergeされるまでclose不可）**。原因調査（Explore subagent）→`RawAudioReaderCapture`のformatをlock保護computed propertyにし、frameのsampleRate/channelCountが変わったら再構築して処理継続（checkpoint用msは`segmentBaselineMS`でsegment境界ごとに確定コミットする方式に変更、rate変化を跨いでも単調前進）→`CaptureStream`の`converter`/`diarizerConverter`を`RebuildableAudioConverter`に変更しbuffer側のformat変化を検知して都度再構築、という設計で実装。`Tests/notetakedTests/`（新設test target）に合成テスト2件追加。**実機再検証（2026-09-20、AirPods Pro 3、blueutilソフトウェア切断、物理操作無し）**: 一時的にstderr debug出力を仕込んだreleaseバイナリで、`.build/release/notetaked capture-daemon`+`serve --input-device CC-22-FE-79-98-E3:input`をpinして起動→24000Hzでframe配信継続を確認→`blueutil --disconnect`→`format rebuilt to 48000.0Hz/1ch`イベント発火を確認→48000Hzでframe配信が途切れず継続することを確認（修正前は#18のバグによりここで配信が永久停止していた）。テスト後、debug出力は`git checkout`で元のcommit内容に復元済み（余分な差分無し）、AirPodsは`blueutil --connect`で再接続済み、production Notetake.appのprocess（PID変更無し）は無傷を確認
  - **#8（短い相槌の話者分裂）: 区切り/停止時の第二パスを実装（commit `9e88004`）。issueはopenのまま（実会話での最終確認が要る）**。user判断（2026-09-20）: 単発の実会話テストは意味が薄いとして見送り、技術設計を優先。既存の`inheritedSpeakerID`（リアルタイム・過去方向のみ、5秒以内）はライブ表示用にそのまま残し、`Reconciler.resolveFallbackSpeakers()`（新規）を区切り/停止時に呼び、speakerIDが無いutteranceを直前・直後両方向の同一device utteranceから再解決（両方一致で採用/片方のみで採用/矛盾や無しならownerLabel維持）。既存の「停止後peer seg遅延到着→final.md再生成」パターンを呼び出し経路として再利用。ユニットテスト3件（直後からの継承・矛盾時fallback・近傍無しfallback）で技術的正しさを担保。実会話での最終確認は次回自然な収録機会に持ち越し
  - **#4（ペアリングコード方式の代替）: 「後がけmergeモード」は保留、QRコードペアリングを実装・実機検証済み（2026-09-20〜21）**。経緯: 「後がけmergeモード」spec（commit `b142c19`、`docs/superpowers/specs/2026-09-20-merge-mode-design.md`）とplan（commit `8e086de`、`docs/superpowers/plans/2026-09-20-merge-mode.md`、9task）まで作成したが、plan中の検討でuserのApple Developer Teamが**未課金（無料）**と判明し、iCloud container entitlement（planのtask 7が前提）が使えないことが確定。userが方針を見直し、issue #4の本来の要望（「ペアリングコードの手入力をやめたい」）に対してはもっと小さい変更で足りると判断し、QRコードペアリング方式へ切り替えた。「後がけmergeモード」のspec/planは実装0件（コード変更なし）のまま棚上げ、将来別の切り口（例: 手動フォルダ選択でのiCloud非依存merge）で再検討の余地を残すためファイルは削除していない
    - **QRコードペアリング（commit `d6b6a2b`）**: 既存のM5 Bonjour+TLS PSK peer接続（`PeerListener`/`PeerClient`、6桁pairing codeをPSKに使う仕組み）自体は無変更、コードの伝達手段だけをQR化した。Mac: pairing codeをSettings Windowから撤去し、menu新規項目「iPhoneとペアリング」（`Apps/Notetake/PairingQRView.swift`、window id `"pairing"`）がQRコード（`Apps/Notetake/QRCodeGenerator.swift`、CoreImageの`CIQRCodeGenerator`のみ、外部依存なし）を表示。「切断」は既存の`regeneratePairingCode()`を再利用。iPhone: `ContentView.swift`のペアリングコード欄を単一ボタン「Macとペアリング」に置き換え、押すとmodal（`Apps/NotetakeMobile/PairingSheet.swift`）が開きVisionKitの`DataScannerViewController`（`Apps/NotetakeMobile/QRScannerView.swift`、iOS 16+）でQRを読み取るか、fallbackの6桁手入力＋「次へ」ボタンで進める。「キャンセル」あり。ペアリング済みなら同じ場所が「ペアリングを解除」ボタンになる（`settings.pairingCode = ""` + 既存の`pairingCodeDidChange()`、PeerClient側の新規ロジック無し）。`Apps/project.yml`に`NSCameraUsageDescription`追加。
    - **実機検証済み（2026-09-20〜21、iPhone 16e）**: Mac側QR表示・「切断」による再生成（コード`356522`→`860971`、QR画像も再描画）はClaudeがSystem Events+screenshotで自律確認。iPhone appのbuild・install・起動・crash無しもClaudeが自律確認（devicectlにUIタップ機能が無くQRスキャン自体はできないため物理操作が必要と判断）。**userが実際にiPhoneで「Macとペアリング」→カメラでQRスキャンしペアリング成立**（メニューに「接続: iPhone」）。user feedback「ペアリングできたらQRコードはとじてほしい」を受け、`connectedPeers`の空→非空遷移で`dismiss()`する自動close機能を追加（commit `08c7759`）。この自動closeはMac appを再起動→pairing codeは変えず（既にpairing済みのiPhoneが自動再接続する）→window表示直後に再接続→window消滅、という手順でClaudeが自律検証（新規の物理スキャン操作は不要）。`make verify`通過（207テスト、警告ゼロ）
  - **#2（iPhone方位軸校正、低優先度）: 文書調査＋仮説ベースの暫定修正・実機未確認（commit `25531d4`、`31107b9`）**。第一段（文書調査、commit `25531d4`）: Apple公式文書（WWDC25 session 251等）を調査、X/Y/Zの数学的役割（前後・左右・上下）は確認できたが**iPhone実機の物理筐体でどちらが+Xかは公式文書に記載が無く**、実機データからの逆算での当てずっぽう修正は避けて保留。`DirectionEstimatorTests`に180°/270°の既知方位合成テストを追加（数式ロジック自体は0/90/180/270いずれも正しく復元することを確認）。第二段（2026-09-20、user承認: 「うまくいかなければ仕方ない、平置きだけ対応して概ね認識できるかを試そう」）: 平置き時は+X（数学上の前後軸）が画面法線（鉛直方向）を向いているという実機データからの推定に基づき、`Recorder.foaChannels(from:)`がDirectionEstimatorへ渡す3ch目をch3(X)からch2(Z)へ差し替え（3軸直交のため+Xが鉛直ならY・Zが水平面を張るはずという推論）。**平置き限定・回転方向の正負は未確認という前提で導入、実機未確認**。`make verify`通過（iOSコンパイル含め警告ゼロ）。次回iPhone実機で4方向計測すれば「軸入れ替えが機能したか」「回転方向・offsetの追加調整が要るか」が1回で判定できる（spec「検証」節に手順あり）
  - **次回セッションで拾うべきこと**: (a) このdraft PRの実機検証状況を見てmerge判断（#18・#4は実機済み、#8は実会話待ち、#2は4方向計測待ち） (b) #2は次回iPhone実機作業のついでに4方向計測 (c) #8は次回の自然な収録で実会話確認
- **Webアプリケーション版（新規構想、2026-09-19、issue未作成）**: user要件を整理
  - Googleログイン必須。データはGoogle Driveを正（source of truth）とし、ローカルはバッファ扱い（永続化不要）
  - 認可はGoogle OAuthで取得。**keychain等の複雑な秘匿保存は絶対NG**。ログインの都度取得し、セッションは可能な限り更新し続ける設計
  - フロントエンドはPicoRuby:wasmで完結させたい（サーバー側の役割を極小化する方向）
  - 任意のGoogleアカウント（Google Workspace含む）を許可するか、特定のWorkspaceドメインのみに絞るかを、**サーバー起動時の設定で固定**できるようにする
  - **次にやること**: Google OAuth（Authorization Code + PKCE、Google Identity Servicesのブラウザ完結フロー等）でトークンをメモリ上のみで扱い永続化しない実装パターン、PicoRuby wasmからのHTTPS/fetch呼び出し可否、Google Drive REST APIでのファイル読み書き範囲（scope）を先に調査すること。まだ設計・spec化前の段階

### branchに入っているもの（段階順 = 検証順）

| 段階 | 内容 | 計画doc |
|---|---|---|
| R 区切る | daemon `rotate`、パネルの開始/停止/区切る、設定「自動で区切る間隔」（既定24時間、0で無停止、app側タイマー）、`fedFrames` UInt64、`levels`時間刈り | `docs/superpowers/plans/2026-09-13-rotation.md` |
| M3 話者分離 | FluidAudio 0.15.7（`NotetakeDiarization`）、`Diarizer` actor、`Aligner`（final pieceを分離結果が覆うまで保留、上限12秒）、`SpeakerRegistry`（cosine 0.7、`g<N>`）、`<prefix>.speakers.json`、大域`~/Library/Application Support/Notetake/speakers.json`、`serve --diarize/--no-diarize`、モデル取得進捗を`log`イベント | `docs/superpowers/plans/2026-09-13-m3-diarization.md` |
| M4 polish | `notetaked polish <timed.jsonl>`（Foundation Models、2000文字chunk、失敗chunkは原文）、`<prefix>.polished.md`、app「直前の収録を整形」/ パネル「整形」 | `docs/superpowers/plans/2026-09-13-m4-polish.md` |
| M5 iPhone | `PeerMessage`（hello/hello_ack/ping/pong/seg/ack）、`ClockOffset`、`SessionMatcher`、`Outbox`、daemon `PeerListener`（Bonjour `_notetake._tcp` + TLS PSK）、`pair_code` command / `peer` event、停止後segのfinal.md再生成、`orphans.jsonl`、Mac設定のペアリングコード、iOS app（Recorder / PeerClient / UI） | `docs/superpowers/plans/2026-09-13-m5-iphone.md` |
| M6 Watch | `WatchChunkMetadata` / `WatchChunkSequencer`、Watch app（20秒AAC小片→`transferFile`）、iPhone `WatchRelay`（小片→専用Transcriber→seg→Outbox） | `docs/superpowers/plans/2026-09-13-m6-watch.md` |
| L 場所情報 / 対話整形 | `make verify`通過。segの`input` / `direction`、`LocationLabel`、`DirectionEstimator`、iPhone `AVCaptureSession` + FOA、状態行とパネルの場所表示、polishの時刻無し対話出力 | `docs/superpowers/plans/2026-09-13-spatial-location-polish.md` |
| V 検証ゲート | `make verify`、`ChunkWriter` init / `WatchRecorder`のbuffer受け渡し / `WatchRelay`の並行性修正、`SampleClock`（iPhone側の時刻基準） | `docs/superpowers/plans/2026-09-13-stage-l-verification-remediation.md` |

## Mac側で行う検証（`main`、上から順に）

原則: **落ちたらまずテストの期待値ではなく実装を疑う（テストが仕様）**。修正はゲート（`make verify`）の結果を全件受け取ってから行い、1件ずつ潰さない。段階ごとに`git commit`（trailer付き）。

### 0. 依存解決とビルド

```bash
swift package --disable-keychain --disable-netrc resolve   # 初回のみ。FluidAudio 0.15.7のbinaryTarget取得にネット必須
make verify   # swift build（警告ゼロ）→ swift test → make app → iOS + watchOSコンパイル（CODE_SIGNING_ALLOWED=NO）。最終行 verify: OK
```

`make verify`は全targetのコンパイルと全テストを機械的に見る。ログは`.build/logs/verify-*.log`。

**実機でしか分からない箇所**（コンパイルは通っている）:
- `Apps/NotetakeWatch/WatchRecorder.swift`: `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`にAAC settingsでPCMを`write(from:)`できるか
- `Apps/NotetakeMobile/Recorder.swift`: FOA取り込みは実機で動作確認済み（`foaChannels(from:)`で直接抽出）。残るは方位の軸校正（issue #2）

### 1. 区切る（R）

1. CLI e2e（rotateで2つのprefixができ、各final.mdに該当発話が入る）:
   ```bash
   make daemon && rm -rf /tmp/nt && mkdir -p /tmp/nt
   ( sleep 3; say -v Kyoko "一つ目の収録です。"; sleep 12; say -v Kyoko "二つ目の収録です。" ) &
   ( sleep 12; echo '{"cmd":"rotate"}'; sleep 14; echo '{"cmd":"stop"}'; sleep 2; echo '{"cmd":"quit"}' ) \
     | .build/release/notetaked serve --output /tmp/nt --owner 小芝 --source system --start --no-diarize | tee /tmp/nt/events.log
   ls /tmp/nt/*.final.md            # 2件
   grep -c '"ev":"status"' /tmp/nt/events.log   # 4（起動時false / --startのtrue / rotateのtrue / stopのfalse）
   grep '"ev":"log"' /tmp/nt/events.log         # rotated <old> -> <new>
   ```
2. `make app` → ライブパネルに 収録開始 / 収録停止 / 区切る / 整形。開始→`say`→区切る→`say`→停止 で保存先に2組。区切った瞬間にパネルがクリアされ状態行のprefixが変わる（userの画面確認）
3. 設定「自動で区切る間隔」に`0.05`（3分）→ 状態行に「次の区切り HH:mm」→ 3分後に自動で区切られ、さらに3分後にもう一度。`0`で「次の区切り」が消える。最後に`24`へ戻す
4. 設定Windowで名前欄にfocusしたまま閉じても値が残る

### 2. 話者分離（M3）

1. 初回: `serve`（`--diarize`既定on）起動時にHugging Faceから`FluidInference/speaker-diarization-coreml`を取得する（`~/Library/Application Support/FluidAudio/Models/`）。stdoutに`{"ev":"log","message":"diarizer models: N0%"}`〜`diarizer ready`。取得失敗時は`error: diarizer unavailable`を出して分離なしで続行する
2. 上記1のe2eを`--no-diarize`無しで実行し、segに`"speaker":{"local":..,"global":"g1","embedding":[...256]}`が付く、`<prefix>.speakers.json`が書かれる
3. 2話者: 日本語2話者の音源（例: `say -v Kyoko`と`say -v Otoya`を交互に）をsystem音声で再生 → final.mdに`**g1**:` / `**g2**:`が分かれる。ライブパネルで話者名クリック→命名 → 以後の行が名前に変わり、`~/Library/Application Support/Notetake/speakers.json`に命名済みcentroidが残る。**次のserve起動（app再起動）で同じ声に同じ名前が付く**
4. 分離ありでは本文が最大約12秒遅れて出る（volatile行で途中経過は見える）。遅延が許容できるかuser判断。CoreML推論は`CaptureStream.ingest`（feed task）内で同期実行しているため、10秒ごとにtranscriberへのfeedが推論時間ぶん遅れる。問題があれば`Diarizer.feed`を`Task.detached`に逃がす
5. `--source both`でmicとsystemは別`Diarizer`（別local id空間）。同一人物のcentroidが`SpeakerRegistry`（閾値0.7）で束なるか確認。割れるなら`SpeakerRegistry.Config.threshold`を下げる

### 3. polish（M4）

1. Apple Intelligenceが有効なMacで `.build/release/notetaked polish /tmp/nt/<prefix>.timed.jsonl` → stderrに`polish: chunk 1/N`、`<prefix>.polished.md`。無効なら`Foundation Models unavailable: <reason>`で非0 exit
2. appのメニュー「直前の収録を整形」/ パネル「整形」（停止または区切り後に有効）→ メニューに「整形完了: <prefix>.polished.md」
3. 失敗chunkがあれば末尾に`> 整形に失敗したturn: N件（原文のまま）`

### 4. iPhone（M5）— 証明書は再発行済み。iPhone 16eの無料profileアプリ上限の解消が前提（「状態」参照）

1. Mac: 設定Windowに6桁ペアリングコード（「再生成」可）。app起動後にdaemonへ`pair_code`が送られ、daemonが`_notetake._tcp`をadvertiseする（`dns-sd -B _notetake._tcp`で見える）。CLI単体なら`serve --pair-code 123456`
2. iPhone: `make project` → Xcodeで`NotetakeMobile`を実機へ（`xcodebuild -scheme NotetakeMobile -destination 'id=<udid>'` + `xcrun devicectl device install app`）。初回にローカルネットワーク許可とマイク許可
3. iPhoneでコードを入力→保存 → 状態が「接続: <Mac名>」、Macのライブパネル状態行に「接続: <iPhone名>」
4. Macで収録開始 → iPhoneで開始 → userが発話 → Macのtimed.jsonlに`"platform":"ios"`のsegと`"t":"device"`（`offset_ms`はping/pongの推定）。final.mdでmic/iPhoneの同一発話が統合される（Reconcilerの±1秒・Dice 0.5）
5. 遅延反映: iPhoneを機内モードで収録→Mac側停止→機内モード解除 → 未ack segが再送され、該当収録の`timed.jsonl`に追記・`final.md`再生成（`log: appended peer seg to <prefix>, final.md regenerated`）。どの収録にも入らない場合は`<output>/orphans.jsonl`
6. 冪等: Macの`~/Library/Application Support/Notetake/received/<device>.cursor`。iPhoneを再起動して同じsegを再送しても二重に入らない
7. iPhone側の話者分離（埋め込み送信）は未実装（specのM5後半）。`NotetakeDiarization`はiOS 17+対応なので、Macと同じ`Diarizer`を`Recorder`に足す

### 5. Watch（M6）

1. `NotetakeWatch`を実機へ。前面で開始 → 20秒ごとに`chunks/<session>-<index>.m4a`が`transferFile`される（未転送数がUIに出る）
2. iPhone側`WatchRelay`が受信 → 専用Transcriber → `"platform":"watchos","source":"watch"`のseg → Outbox → Mac。Watchの録音停止後60秒で該当streamを`finish()`
3. Macのfinal.mdでWatch由来segがmic/iPhoneと統合される（source優先度 system > mic > watch）
4. 未確認事項: watchOSの`inputNode`のフォーマットとAAC書き出し、`WCSession`の背景転送、`AVAudioFile(forReading:)`でのAAC→PCM（`processingFormat`）

### 6. 場所情報 / 対話整形（L）

1. Mac: 収録開始→発話→停止。`timed.jsonl` の seg に `"input":{"name":"MacBook Airのマイク","uid":"BuiltInMicrophoneDevice","spatial":false}`、final.md の行が `**話者**（Mac）:`。パネル状態行に `入力: MacBook Airのマイク（空間: 非対応）`
2. AirPods Pro 3 を接続して既定入力にし「区切る」→ 新しいprefixのsegが `"name":"ゆふAirPods Pro 3"`、行が `（AirPods）`
3. `notetaked polish <prefix>.timed.jsonl` → 先頭 `# yyyy-MM-dd 参加者`、行に時刻無し
4. iPhone: `input.spatial` は iPhone 16e で true（確認済み）。方位の軸校正は issue #2（平置きで上端側 → `≈ 0`、右側 → `≈ 90` になるまで）

## 申し送り（Mac必須・user作業を含む）

- **Apple Development証明書は再発行済み**（有効identity `A3F23595F28DC4E18B5063DF519E424A44778AB4`、失効した3本もkeychainに残る）。iOS / watchOSは`Apps/project.yml`のbase設定（`Automatic` + Team `SM5792D355`）でそのまま実機署名できる。daemon / mac appは**まだad-hoc署名のまま**（`Makefile`の`DAEMON_IDENTITY ?= -`、mac targetの`CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`）。本物の署名へ切り替えると署名が変わりTCC（マイク / システム音声）の再許可ダイアログが出るため、**userが画面の前にいる時に**: `make app DAEMON_IDENTITY=A3F23595F28DC4E18B5063DF519E424A44778AB4` と、project.ymlのmac targetから`CODE_SIGN_STYLE: Manual` / `CODE_SIGN_IDENTITY: "-"`の2行を削除して`make app`
- **TCC**: ad-hoc署名でrebuildすると再許可が要る可能性（未確認）。appが子processで起動したdaemonのマイク／システム音声許可は親app（Notetake.app）に帰属。`tccutil reset Microphone/AudioCapture io.github.bash0c7.notetake`でリセット可
- **`swift package resolve`のbinaryTarget取得はkeychain照会で落ちる**（`Failed to find credentials for 'https://github.com' in keychain: status -128`）。`swift package --disable-keychain --disable-netrc resolve`で回避。Bash sandbox内ではgit cloneが途中で止まるためsandbox外で実行
- **ネットワークが要る初回処理**: FluidAudioモデル（Hugging Face）、`swift package resolve`のbinaryTarget（GitHub releases）、ja-JP音声モデル（済み）。オフライン化（モデルのapp同梱）は未対応
- **Foundation Models**: Apple Intelligence有効なM3 Mac。sessionあたり4096 token。`--max-characters`でchunkを小さくできる
- **FluidAudioの推論負荷**: 2 stream同時（mic + system）でのCPU/メモリを`make app`後にアクティビティモニタで確認。10秒chunkごとに数百ms想定
- **iPhone / Watch**: 実機はuserの操作（発話・機内モード・Watch画面操作）が必要。Claudeは`xcodebuild` / `devicectl`でインストール・起動し、Mac側のtimed.jsonl / final.mdを確認する
- **PRの粒度**: 1本のbranch（この session の指定branch）にR〜M6を積んである。段階ごとに切り出したければ`git rebase -i`でcommit範囲ごとにbranchを作る（commitは段階順に並んでいる）

## 設計上の割り切り・既知の未実装

- **daemonの状況表示・監視・起動終了はメニューバーapp（Notetake.app）が司る**（user方針、2026-09-14）。現状: `AppModel.ensureDaemon()`が子processとして起動し設定変更で再起動、`DaemonClient`の`terminationHandler`で落ちたら再起動（60秒に複数回落ちる場合は抑止）、app終了時に`quit`を送って待つ、`log` / `error` / `peer`イベントをメニューに表示。issue #7（peer生存検知）もこの枠で扱う。CLI単体の`serve`は検証用

- 区切り（`rotate`）は中間の停止statusを出さないため、録音中に変えた設定（名前・保存先）の`restartPending`再起動は次の明示的な停止まで持ち越す
- 話者分離: specの「本文を即表示して後から話者だけ差し替え」は採らず、`Aligner`で最大12秒保留してから話者付きで出す（timed.jsonlにはfinalだけ書く原則を保つため）
- `SpeakerRegistry`は1回のserve起動の間だけ`g<N>`を保持。命名していない話者はserve再起動で`g1`から振り直し（命名済みは大域プロファイルで引き継ぐ）
- `levelForPiece`: pieceの時間範囲にbufferが無い時のfallback `-120`は未対応
- daemon再起動後に同じ接頭辞で収録を再開する要件（spec）は未実装
- `DaemonClient`: stdout chunkごとのTask hopがFIFO前提 → AsyncStreamで直列化（未対応）
- Transcriber: 変換ごとの`AudioConverter.reset()`が認識品質に与える影響のA/B未実施
- **内蔵マイク+内蔵/外部スピーカーで`--source both`を使う場合、スピーカーの音をマイクが拾ってしまい（音響的な回り込み）、system音声とほぼ同じ内容がmic側にも別発話として二重に載る（2026-09-16、user確認・意図的に未対応のまま残す判断）**。`Reconciler.bestCandidateIndex`は`!utterance.devices.contains(seg.device)`（同一`device`同士は統合しない。`sameDeviceNeverMerges`テストが担保するdevice内自己重複防止のためのガード）を条件にしており、Macの`--source both`ではmic segとsystem segが同じ`device` idを持つため、テキストが似ていてもこのガードで弾かれ統合対象にならない。既定のアプリ内`polish`（Foundation Models、`Sources/notetaked/Polish/Polisher.swift`）はこの重複を解消しない設計: instructionsに「要約しない」「本文turnと同じ件数・同じ順で返す」と明記しており、`PolishChunker.turns`も連続する同一speakerラベルのutteranceしか結合しない（mic側とsystem側は通常ownerラベルが違うため結合対象にすら入らない）ため、重複はpolish後もそのまま残る可能性が高い。**回避策として、アプリ側の重複排除は実装せず、`final.md`を外部の汎用AI（ChatGPT/Claude等）へコピペして「読みやすい議事録にして」と整形依頼する運用に委ねる方針とした**（外部AIへの一般的な整形依頼はpolishのような「同じ件数で返す」制約が無いため、隣接する類似内容の行を自然にまとめてくれる想定。ただしmic側とsystem側で話者ラベルが違うため、話者取り違えのリスクは残る）。ヘッドホン使用（AirPods等）で物理的に回り込みを断つのが最も確実な回避策で、これは既に対応済み（#14の入力デバイス追随修正により接続するだけで機能する）。アプリ側のReconciler修正（同一device+テキスト類似の統合除外）は行わない判断
- iPhone側の話者分離・埋め込み送信、Watchのownerを`WCSession.applicationContext`で同期、`hello`のowner名変更の即時反映は未実装

## ドキュメント

- 設計spec（M0〜M6の全体設計、binding authority）: `docs/superpowers/specs/2026-09-12-notetake-design.md`
- 実装計画: `docs/superpowers/plans/2026-09-12-m0-m2-mac-core.md`（完了）/ `2026-09-13-rotation.md` / `2026-09-13-m3-diarization.md` / `2026-09-13-m4-polish.md` / `2026-09-13-m5-iphone.md` / `2026-09-13-m6-watch.md`（いずれも`make verify`通過・実機検証待ち）
- project instructions（モデル分担・SDDの手順・署名の注意）: `CLAUDE.md`。全体像: `README.md`。決定論的な手順のskill: `.claude/skills/`（`verify` / `mac-app` / `device` / `recordings`）

## いま動くもの（使い方）

- app: `make app` → `.build/DerivedData/Build/Products/Debug/Notetake.app`。設定Windowで保存先・自分の名前・自動で区切る間隔・ペアリングコード（UserDefaults `io.github.bash0c7.notetake` の `outputDirectory` / `ownerName` / `rotationIntervalHours` / `pairingCode`）。daemonは`serve --output <dir> --owner <name> --source both --control stdio`で起動され、起動直後に`pair_code`を受け取る
- CLI: `make daemon` → `.build/release/notetaked`。subcommand: `serve`（stdin `{"cmd":"start"|"stop"|"rotate"|"rename_speaker"|"pair_code"|"quit"}`、stdout `{"ev":"status"|"utterance"|"volatile"|"peer"|"error"|"log",...}`、`--diarize/--no-diarize`、`--pair-code`）/ `render <timed.jsonl>` / `polish <timed.jsonl>` / `transcribe <audio file>` / `capture --source mic|system --seconds N`
- 出力: `<prefix>.live.txt` / `.timed.jsonl` / `.final.md` / `.speakers.json` / `.polished.md`、`orphans.jsonl`

## 環境の注意

- git push / ghはBash sandboxでは資格情報が読めない → sandboxを無効にして実行。sandbox内で`~/.gitconfig`が読めない時は`GIT_CONFIG_GLOBAL=/dev/null`（repo localにuser.name/email設定済み）
- `make verify`はxcodebuildのpackage解決を含むため、DerivedDataにpackageが無い初回はBash sandbox内で止まることがある → sandbox外で実行。2回目以降はsandbox内で通る
- system音声tapの特性: 音を出しているprocessが無い間はbufferが1つも来ない（無音のまま停止しても`Transcriber.finish()`は入力0の高速経路で戻る）
- ja-JP音声モデルはダウンロード済み。日本語TTS voiceはKyoko / Otoya
- 実機probe（2026-09-13）: Macに繋がる機材（内蔵マイク / AirPods Pro 3 / ContinuityのiPhone）はいずれも`isMultichannelAudioModeSupported(.firstOrderAmbisonics)`がfalse、入力1ch。空間収録はiPhone本体でのみ試せる（iPhone 16eの対応可否は実機で判定）
- **メモリ**: 収録（分離あり）中に`make verify`と実機向けxcodebuildを並行させると24GBでもメモリ不足になりbackground taskが落ちる。ビルドは直列に。収録中のdaemon/appのRSS推移は計測済み（issue #9、2026-09-16、約6.5時間でdaemonは92〜101MBで横ばい、appは205→228→163→170MB前後で安定。詳細は上の状態欄）
- `make app`で`.build/release/notetaked`を更新してもbundle内が古いままの場合は`Apps/project.yml`のEmbed scriptの`inputFiles`を確認（16d68b1で追加済み）
- Claude Code on the web（Linux）にはSwiftツールチェーンが無く、swift.orgもproxyで403。Swiftの実行が要る作業はMac側セッションで

## 検証コマンド

- `make verify`（ゲート。全targetのビルド警告ゼロ・全テスト・mac app・iOS + watchOSコンパイル。最終行`verify: OK`）
- `make test` / `make daemon` / `make project` / `make app`
- `swift build 2>&1 | grep -i warning`（出力なしが正常）

## GitHub

- public repo: https://github.com/bash0C7/notetaked（default `main`）
- draft PR: https://github.com/bash0C7/notetaked/pull/1（branch `claude/jolly-fermi-mi44i4`）
