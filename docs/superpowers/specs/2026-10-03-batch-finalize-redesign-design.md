# 収録の確定処理（batch話者分離）と内部構造の整理

## 背景

### 話者分離が別の人を同じ人にする

収録中の話者分離は、FluidAudioのオンライン版（`DiarizerManager`）が10秒ごとに話者を決め、`SpeakerRegistry`が大域idへ束ねている。実収録4本では、どれも1人の話者が発話の大半を吸収し、残りが数件ずつの細かい話者に割れている。

| 収録 | source | 発話数 | 最大の話者の占有 | 話者数 |
|---|---|---|---|---|
| 2026-10-01 20:02（212分） | system | 449 | 61% | 4 |
| 2026-10-01 15:07（101分） | mic | 314 | 80% | 10 |
| 2026-09-30 13:36（38分） | system | 179 | 74% | 6 |
| 2026-09-29 15:30（94分） | mic | 553 | 73% | 8 |

原因は3つある。

- オンライン版は、最も近い既存話者のcentroidへ吸着させながらcentroidを更新し続ける。最初の話者のcentroidが全員の平均へ寄り、吸引源になる。FluidAudioのbenchmark文書も、streaming版はclusteringが脆く話者混同が重いと書き、たいていの用途はオフライン版で足りるとしている
- `SpeakerRegistry`の割り当て表は`serve`プロセスの寿命で残る。一方`Diarizer`は収録ごとに作り直され、local idは毎回`1`から振られる。割り当て済みのキーは埋め込みを比べずに既存の大域idを返す。このため区切りの後に最初に話した人は、誰であっても前の収録の`1`と同じ大域idになる
- 分離結果が間に合わない短い発話は、直前の発話の話者を継承する。これも同じ人へ寄せる方向に働く

### 発話の時刻が最大138分早く記録される

capture-daemonが書く生音声（`<source>.raw`）には時刻が無い。読み手は音声が途切れず続くと仮定し、先頭からのsample数で時刻を計算している。micは機器の切り替えや再開の失敗で途切れるため、その後の発話の時刻が実際より早く記録される。

| 収録 | source | 経過時間 | 生音声の長さ | 発話時刻のずれ |
|---|---|---|---|---|
| 2026-10-01 20:02 | mic | 212分 | 85分 | 最大138分早い |
| 2026-10-02 13:06 | mic | 640分 | 507分 | 全36件が約134分早い |

### ディスプレイが消灯するとsystem音声が止まったままになる

ScreenCaptureKitは、ディスプレイの消灯でstreamを自ら止める。2026-10-02 13:43:30のlogでは、`kCGSDisplayWillSleep`の直後に`Stopping stream due to stream frameStatus=5`が出ている。`SystemAudioCapture`はdelegateを持たないため停止に気づかず、再開しない。2026-10-02の収録は640分のうち37分しかsystem音声が残っていない。映像の出力を登録していないため、収録中は毎秒`stream output NOT found. Dropping frame`のerror logも出る。

### 生音声と一時ファイルが残り続ける

- 生音声は入力機器のformatのまま書かれる。48kHz stereoのFloat32なら、1 sourceあたり毎時約1.4GBになる。削除する処理が無く、9収録分の15GBがtmpに残っていた
- `Heartbeat`・`CaptureCheckpoint`・`CaptureControlChannel`は、`.atomic`で書いた一時ファイルをさらに`replaceItemAt`で入れ替える。その失敗を`try?`で捨てるため、状態ディレクトリに一時ファイルが612個残っていた

### 構造が込み入っている

- `ServeSession`（860行）は責務が11ある。収録の寿命、capture-daemonとのIPC、文字起こしpipelineの組み立て、話者付け、命名、peer接続、peer発話の振り分け、収録一覧のcacheが1つのactorに同居する
- `CaptureStream`（349行）は、話者分離用の2本目の形式変換、bufferごとの`Task.detached`の連鎖、12秒保留の`Aligner`、2秒周期のdrain、停止時のtimeoutを抱える。timeoutの補助関数は、取り消しに応じない子taskを`withTaskGroup`が待つため、期限が来ても返らない
- `AppModel`（517行）は、設定が変わるたびに`serve`を再起動する。そのための状態変数を9個持つ
- capture-daemonが書く`started` / `stopped` / `error`のeventを誰も読まない。取り込みの起動失敗は、10秒後に原因不明のtimeoutとして現れる
- `final.md`を作る経路が3つあり、話者の二次解決の有無が違う
- 音声のcallback上で、bufferごとの確保、1 sampleずつのコピー、ファイルへの書き込みを行う
- I/Oや変換の失敗を捨てる`try?`が84行ある

## ゴール

- 話者は収録単位でまとめて決める。区切りまたは停止の後、その収録の生音声全体に対して文字起こしとオフライン話者分離をやり直し、完成版の`final.md`を書く
- 収録中の表示は文字起こしだけにする。話者のラベルは、micが所有者名、systemが「リモート」の2種類にする
- 出力するすべての時刻を壁時計に合わせる。音声が途切れても時刻はずれない
- ディスプレイの消灯や機器の切り替えで止まった取り込みを、自動で再開する。再開できない間は、その状態をメニューに出す
- 生音声は、確定処理が成功したら消す
- 責務ごとに型を分け、収録中の話者分離に関わる仕組み、再開位置の記録、使われていない機能を取り除く

## 非ゴール

- iPhone appとWatch appの整理。peerの通信形式は変えない。iPhoneとWatchの整理は別のspecで扱う
- 整形（polish）の変更。整形は確定後の記録をそのまま入力にする
- iPhone側での話者分離
- 収録中に表示した暫定の発話を、確定版で置き換えて見せること

## 方針

収録中は速さを取り、確定では正しさを取る。

- **収録中（ライブ）**: 文字起こしだけを行う。ライブパネル、`live.txt`、`timed.jsonl`の暫定の発話に使う
- **確定（finalize）**: 区切りまたは停止の後に、その収録の生音声全体を一括で処理する。文字起こしとオフライン話者分離をやり直し、話者付きの発話で暫定の発話を置き換える
- **生音声は確定までの正本**: capture-daemonが書く生音声を、確定処理の入力にする。確定が成功するまで消さない。`serve`が落ちても、確定処理は生音声から全体を作り直すため、収録中の処理位置を記録して再開する仕組みは要らない

## 確定処理にかかる時間の実測

Apple M4 Pro（メモリ48GB、macOS 27.0.1）で、tmpに残っていた実収録の生音声を使い捨ての計測用subcommandで処理した。話者分離のmodelは取得済みの状態で、文字起こしと話者分離を順に行った。

| 収録 | source | 音声の長さ | 一括文字起こし | オフライン話者分離 | 話者数（収録中の分離 → オフライン） |
|---|---|---|---|---|---|
| 2026-10-01 15:07 | mic | 112分 | 61秒（実時間比111倍） | 15秒（実時間比455倍） | 10 → 3 |
| 2026-10-01 20:02 | system | 214分 | 112秒（実時間比114倍） | 27秒（実時間比475倍） | 4 → 5 |
| 2026-10-02 13:06 | mic | 507分 | 227秒（実時間比134倍） | 62秒（実時間比490倍） | 3 → 2 |

- 1時間の収録なら、1 sourceの確定は1分以内に終わる
- 一括文字起こしの文字数は、収録中の文字起こしとほぼ同じか1〜2%多い。15:07の収録は15,364字から15,575字、20:02の収録は24,446字から24,933字、13:06の収録は780字から788字だった
- 15:07の対面の収録では、収録中の分離は10人に割り、1人に発話の80%を寄せていた。オフライン版は3人に分け、各人の発話は22.7分・19.2分・13.0分だった
- 同じ収録の異なる話者のcentroid同士のcosine類似度は、最大で0.57（15:07）・0.62（20:02）・0.14（13:06）だった
- 話者分離の段階で増えたメモリは、112分の収録で約0.6GBだった
- 一括文字起こしの結果は、文字ごとに時間範囲を持つ

## 全体構成

```
Notetake.app（メニューバー）
  ├─ notetaked capture-daemon：取り込みだけ。<tmp>/notetake-capture/<prefix>/へ書く
  └─ notetaked serve：ライブの文字起こし・peer受信・出力ファイルの唯一の書き手
       └─ notetaked finalize：serveが収録ごとに起動する子process。結果をファイルで返す
```

| process | 責務 | 寿命 |
|---|---|---|
| Notetake.app | 2つの常駐processの起動・監視・再起動、UI、整形の起動 | 常駐 |
| capture-daemon | mic・system音声の取り込み、16kHz monoへの変換、生音声と時刻情報の書き込み、取り込みの自動再開 | 常駐 |
| serve | 収録の開始・停止・区切り、ライブの文字起こし、iPhone・Watchの発話の受信と振り分け、出力ディレクトリへの全書き込み、確定処理の順番待ちと取り込み | 常駐 |
| finalize | 1収録ぶんの一括文字起こしとオフライン話者分離 | 1収録の処理中だけ |

出力ディレクトリへ書くのは`serve`だけにする。finalizeは結果をtmp側のファイルに書き、`serve`がそれを読んで出力ディレクトリへ反映する。

## 生音声の形式

1収録のディレクトリ`<tmp>/notetake-capture/<prefix>/`に、sourceごとに2つのファイルを置く。

| ファイル | 中身 |
|---|---|
| `<source>.pcm` | 16kHz mono Float32 little endianのsampleを、headerを付けずに追記し続ける |
| `<source>.meta.jsonl` | 時刻の基準点、入力機器の変更、取り込みの停止と再開を1行ずつ追記する |

`<source>.pcm`はheaderを持たないため、読み手はbyte offsetを4で割ればsample番号が分かる。確定処理はこのファイルをmemory mapし、FluidAudioの`AudioSampleSource`としてそのまま渡せる。保存量は1 sourceあたり毎時約230MBになる。

`<source>.meta.jsonl`の行は3種類ある。

```json
{"t":"anchor","sample":0,"ms":1790999999000}
{"t":"device","sample":0,"device":{"name":"MacBook Proのマイク","uid":"BuiltInMicrophoneDevice","spatial":false}}
{"t":"state","sample":81920,"ms":1791000004120,"state":"retrying","reason":"The stream was stopped by the system"}
```

- **anchor**: sample番号と壁時計（epoch ms）の対応。sample `n`の時刻は、`n`以前で最後のanchorから16kHzで進めて求める
- **device**: そのsample以降の入力機器。micだけが持つ
- **state**: 取り込みの停止や再開の記録。表示と調査に使う

書き手は、bufferを受け取った時刻からbufferの長さを引いて、その先頭sampleの壁時計を求める。この時刻と、直前のanchorから計算した時刻の差が250msを超えたら、新しいanchorを書く。音声が途切れた場合と、音声の時計が壁時計からずれた場合を、この1つの規則で扱う。250msはcallbackの揺らぎより大きく、異なるdeviceの発話を統合する許容幅（1秒）より小さい。

## capture-daemon

### 取り込みと書き込み

- sourceごとに`SourceRecorder`を1つ持つ。`SourceRecorder`は、入力機器のformatから16kHz monoへの変換器と、`.pcm`と`.meta.jsonl`の書き手を持つ
- 音声のcallbackでは、sampleを新しいbufferへ写して受け取り時刻を付け、直列のdispatch queueへ渡すだけにする。変換、anchorの判定、ファイルへの書き込みはそのqueueで行う
- 入力機器のformatが変わったら、変換器を作り直す。formatの変化を扱うのはこの1箇所だけになる
- 書き込みの失敗は捨てず、`state`行と実状態ファイルの`lastError`に残す

### 自動再開

- **system**: `SCStreamDelegate`の`stream(_:didStopWithError:)`で停止を知る。停止したら`retrying`を記録し、5秒ごとに`SCShareableContent`の取得からstreamを作り直す。ディスプレイが点灯すれば再開できる。消灯中にstreamを作り直せない間のsystem音声は欠ける。常駐で長時間収録するため、消灯を防ぐ指定はしない。映像の出力も登録し、届いたframeは捨てる
- **mic**: `AVAudioEngine`の構成変更通知で張り直す動作は残す。`engine.start()`の失敗を捨てず、1秒・2秒・4秒と間隔を広げながら最大30秒間隔で再試行する。固定した機器が外れたら既定の入力へ戻し、その事実を実状態ファイルに出す

### 区切りで音声を落とさない

区切りでは取り込みを止めない。書き込み先のディレクトリだけを、bufferの境目で新しい収録へ切り替える。新しい収録の`.meta.jsonl`は、切り替えた時点のanchorとdeviceから始まる。

### serveとの受け渡し

コマンドとeventのやりとりを、望む状態と実際の状態の2つのファイルに置き換える。どちらもApplication Supportの`Notetake/state/`に置く。

| ファイル | 書き手 | 中身 |
|---|---|---|
| `capture-desired.json` | serve | 収録中のprefixとディレクトリ（停止中はnull）、使うsource、固定する入力機器のUID |
| `capture-actual.json` | capture-daemon | process id、いま書いているprefix、sourceごとの状態（`recording` / `retrying` / `off`）・入力機器・固定機器から戻ったか・最後のエラー、更新時刻 |

- capture-daemonは200msごとに望む状態のファイルの更新時刻を見て、変わっていれば読み直して取り込みを合わせる。実状態は1秒ごとに書く。実状態ファイルの更新時刻が、capture-daemonの心拍を兼ねる
- capture-daemonが再起動しても、望む状態を読み直せば同じ収録へ追記を続けられる。古いコマンドを再生する問題は形の上で起きない
- serveは実状態を1秒ごとに読む。sourceの状態が変わったら`status` eventでappへ伝える。固定機器から既定の入力へ戻ったら`input_reset` eventを1回送る
- 収録中かどうかも望む状態ファイルで表すため、再開マーカー（`current-session.json`）は使わない
- 書き込みは、同じディレクトリの一時ファイルへ書いてからrenameする1つの補助関数にまとめる。心拍ファイルも同じ補助関数で書く

## serve

### ライブの文字起こし

- sourceごとに`LiveTranscription`を1つ持つ。`<source>.pcm`を開いたまま末尾を100msごとに読み、文字起こしの入力形式（16kHz monoのInt16）へ変換して`Transcriber`へ渡す。resampleは無い
- 発話の時刻は`.meta.jsonl`のanchorから求める。入力機器はdevice行から、音量（dBFS）は発話の時間範囲のsampleから求める
- `serve`の再起動後は、既存の`timed.jsonl`を畳み込んでから、`.pcm`の現在の末尾から読み始める。再起動の間の音声は、ライブ表示には出ないが確定処理で拾われる
- 停止と区切りでは、ライブの文字起こしを`cancelAndFinishNow()`で打ち切る。最後の数秒の暫定の発話は残らないことがあるが、完成版は確定処理が作る

### 停止と区切り

1. ライブの文字起こしを打ち切る
2. `timed.jsonl`へ`session_end`の記録を足す
3. 暫定の発話で`final.md`を書く。確定処理が失敗しても、この版が残る
4. 望む状態を、停止なら空に、区切りなら新しい収録に書き換える
5. 確定処理の順番待ちへ、その収録を入れる

### 確定処理の順番待ちと取り込み

- 順番待ちは1本ずつ処理する。capture-daemonがその収録への書き込みを終えたこと（実状態のprefixが別になったこと）を確かめてから始める
- `notetaked finalize`を子processとして起動する。`qualityOfService`は`.utility`にして、ライブの文字起こしを優先させる。子processのstderrの進捗を`log` eventでメニューへ流す。進捗が5分途絶えたら止めて失敗とする
- 子processが成功したら、結果ファイルを取り込む
  1. 話者に収録内のid（後述）を振り、命名済みの話者profileと照合する
  2. 確定版の発話、`speaker_name`、`finalized`の記録を`timed.jsonl`へ1回の書き込みで足す
  3. `<prefix>.speakers.json`と`final.md`を書き直す
  4. 収録の生音声ディレクトリを消す
  5. `finalized` eventで、収録のprefixと話者の一覧をappへ伝える
- 取り込みは何度行っても同じ結果になる。`timed.jsonl`に`finalized`の記録が既にあれば、追記を飛ばして`final.md`だけ書き直す
- 起動時に生音声ディレクトリを調べ、収録中でないものを順番待ちへ入れる。結果ファイルがあれば取り込みから、無ければ確定処理から始める
- 試行の回数を生音声ディレクトリに記録し、3回失敗したらその収録は諦めてエラーを出す。生音声は残し、tmpの掃除に任せる

### 出力ファイルの書き手

出力ディレクトリへの書き込みを`SessionArchive`（actor）1つにまとめる。

- いまの収録の`timed.jsonl`・`live.txt`への追記
- 過去の収録の`timed.jsonl`への追記（遅れて届いたpeerの発話、確定処理の結果、命名）
- `orphans.jsonl`への追記
- `final.md`と`<prefix>.speakers.json`の書き直し
- 収録の一覧（peer発話の振り分けに使う）。ファイルの更新時刻を覚え、変わったファイルだけ読み直す

`final.md`を作る関数は1つにする。`serve`、`notetaked render`、整形のすべてが同じ関数を通る。

### peer

`PeerHub`（actor）へ移す。listenerの起動と停止、hello・ping・pong、時計のずれの推定、受信の重複排除、発話の振り分け（いまの収録・過去の収録・orphans）を受け持つ。通信形式は変えない。時計のずれの標本は直近の20件だけ持つ。

### 残る`ServeSession`

`ServeSession`はstdinのコマンドの振り分けと、収録の開始・停止・区切りだけを受け持つ。ライブの文字起こし、`SessionArchive`、`PeerHub`、確定処理の順番待ちを組み合わせる。

## finalize

### 入力と出力

```
notetaked finalize <生音声ディレクトリ> --device-id <id> --device-name <name> --owner <所有者名>
```

- 入力は、生音声ディレクトリにあるsourceごとの`.pcm`と`.meta.jsonl`
- 出力は、同じディレクトリの`finalize.json`。一時ファイルへ書いてからrenameする。中身は、sourceごとの確定版の発話と、話者ごとのcentroid・合計発話秒数・最初の発話の抜粋
- 出力ディレクトリには書かない

### 処理

sourceごとに次を行う。1つのsourceの中では、1と2を並行に走らせる。

1. **一括文字起こし**: `.pcm`を先頭から読み、文字起こしの入力形式へ変換して`SpeechAnalyzer`へ渡す。入力は引き取り型のAsyncSequenceにして、読む速さを文字起こしの速さに合わせる。結果は文字単位の時間範囲を持つ
2. **オフライン話者分離**: `.pcm`をmemory mapした`AudioSampleSource`を`OfflineDiarizerManager.process(audioSource:)`へ渡す。話者ごとの区間と、`speakerDatabase`のcentroidを得る
3. **話者の割り当て**: 文字単位の区間ごとに、重なりが最大の話者を選ぶ。重なりが無い区間は、時間的に最も近い区間の話者を使う。同じ話者が続く範囲を1つの発話にまとめる
4. **時刻と属性**: sample番号をanchorで壁時計へ直す。入力機器はdevice行から、音量は発話の範囲のsampleから求める

話者分離のmodelは、初回だけHugging Faceの`FluidInference/speaker-diarization-coreml`から取得する（約30秒）。2回目以降はApplication Supportのcacheを使う。

## 話者の識別と命名

- 確定処理の話者は、収録の中で最初に話した順に`s1`、`s2`…と振る。micとsystemの話者は別の話者として数える
- 命名済みの話者profileと、各話者のcentroidをcosine類似度で比べる。0.7以上の中で最も近いprofileの名前を付ける。実測では同じ収録の異なる話者同士が最大0.62だったため、0.7はそれより上に余裕を取った値である。1つのsourceの中で、同じprofileを2人の話者に付けない。類似度の高い組から順に決める
- 名前の無い話者は「話者1」「話者2」…と表示する
- 命名は確定後に行う。ライブパネルの末尾に、直前に確定した収録の話者の一覧（表示名、発話秒数、最初の発話の抜粋）を出し、既存の改名popoverで名前を付ける。`rename_speaker`コマンドは`prefix`を受け取る
- 命名すると、`serve`はその収録の`timed.jsonl`へ`speaker_name`を足して`final.md`を書き直す。その話者のcentroidを名前付きの話者profileとして保存する。同じ名前のprofileが既にあれば、centroidを発話秒数で重み付けして平均する
- 話者profileは`~/Library/Application Support/Notetake/speaker-profiles.json`に置く。オンライン版とオフライン版はmodelのファイルが異なり、埋め込みの互換が保証されない。そのため従来の`speakers.json`は読まない
- 収録中のライブパネルでは命名できない。収録中の発話には話者が付かないため

## 記録形式の変更

`timed.jsonl`は追記だけの形を保つ。

| 変更 | 内容 |
|---|---|
| `seg`に`pass`を追加 | 確定版は`"pass":"final"`。無ければ暫定版 |
| `finalized`の記録を追加 | `{"t":"finalized","device":"<Macのdevice id>","sources":["mic","system"]}` |
| `session_end`の記録を追加 | `{"t":"session_end","ended":<epoch ms>}`。収録の一覧が終了時刻に使う |
| `seg.speaker` | 確定版は`{"local":"mic:S1","global":"s1"}`。埋め込みは`speakers.json`だけに置き、`timed.jsonl`には書かない |

`Reconciler.fold`は、`finalized`があるdeviceとsourceの組について暫定版の発話を無視し、確定版の発話を使う。暫定版だけの収録は従来どおり描画する。過去の収録の`timed.jsonl`もそのまま読める。過去の`final.md`は書き直さない。

`Reconciler`から、直前の話者の継承と停止時の二次解決を取り除く。話者の無い発話は、従来どおりdeviceの所有者名（systemは「リモート」）で表示する。

## Notetake.app

- 設定（保存先、所有者名、固定する入力機器、ペアリングコード）を、起動時と変更時に`configure`コマンドで`serve`へ送る。`serve`は保存先と所有者名を次の開始か区切りから使う。入力機器はすぐに望む状態へ反映する。設定の変更で`serve`を再起動しないため、再起動の延期に使う状態変数を取り除く
- `serve`の再起動は、異常終了とハングの場合だけにする。60秒に5回までの制限は残す
- `serve`の心拍は`ServeSession`のactorの中から5秒ごとに書く。actorが止まれば心拍も止まる
- capture-daemonの生存は、実状態ファイルの更新時刻で判断する。process終了は`terminationHandler`で知る
- `DaemonClient`は、stdoutを`FileHandle.bytes.lines`で行ごとに読む。終了待ちは`terminationHandler`で受ける
- メニューに、sourceごとの取り込みの状態と、確定処理の進捗を出す
- 「整形」は、確定処理が終わった収録に使える。確定を諦めた収録では、暫定版を整形する。メニューとライブパネルの操作ボタンと状態文は、同じ関数から作る
- `AppModel`を、設定、2つのprocessの監視、eventから表示状態への反映、整形の実行に分ける

## 構造と記述の整理

- **補助関数の統一**: 原子的な書き込み、1行のJSONの符号化と復号、Application Supportの場所、現在時刻のms、sample数とmsの換算を、それぞれ1つにする
- **使われていないものを消す**: `PeerListener.broadcast`、`MicCapture.currentInputDevice`、`InputDeviceProbe.resolve(uid:)`、`CaptureSessionRunner.isRunning(directory:)`、`transcribe`と`capture`のsubcommand、`serve`の`--control`と`--locale`と`--diarize`、macOS専用のtargetにある常に真の`#if canImport(Speech)`と`@available`
- **commentの書き方**: issue番号、過去の不具合、検証の経緯をcommentに書かない。いまのcodeが守る前提と、その理由だけを書く
- **エラーの扱い**: 発話や音声を失う`try?`をやめ、`error` eventかlogに出す。失敗してよい処理（一時ファイルの削除など）に限って`try?`を使う
- **`Reconciler`の速さ**: 取り込み済みのseg idを集合で持つ。統合先の候補は開始時刻の二分探索で絞る

## 取り除くもの

| 対象 | 理由 |
|---|---|
| `Diarizer`（オンライン版）とその初期化・model事前取得 | 収録中に話者分離をしない |
| `Aligner`の保留・drain・期限 | 区間の割り当ては確定処理の純粋関数に移す |
| `SpeakerRegistry`の割り当て表 | 話者は収録単位で決める。cosine類似度とcentroidの計算は話者profileの照合に残す |
| `ProfileNameAnnouncer` | 名前は確定の取り込みで記録する |
| `Reconciler`の話者の継承と二次解決 | 確定処理が全発話に話者を付ける |
| `CaptureCheckpoint`、`RawAudioReaderCapture`の位置対応表、再開マーカー | 再開位置を記録しない |
| `RebuildableAudioConverter`、読み手側のformat変化の処理 | 変換はcapture-daemonの1箇所で行う |
| `RawAudioFrame`・`RawAudioReader`・`RawAudioWriter` | 生音声の形式を置き換える |
| `CaptureControlChannel`、`CaptureCommand`、`CaptureEvent`、`capture.heartbeat` | 望む状態と実状態のファイルに置き換える |
| `.claude/skills/recordings/scripts/fallback-diff.sh` | 二次解決が無くなる |

## エラーの扱い

| 状況 | 動き |
|---|---|
| 取り込みが止まった | capture-daemonが再試行する。メニューに「system音声: 再開待ち」などを出す |
| 生音声の書き込みに失敗した | 実状態の`lastError`に出し、serveが`error` eventで伝える |
| 確定処理が失敗した | 暫定版の`final.md`が残る。次の起動で再試行し、3回で諦める |
| 話者分離のmodelを取得できない | その回の確定処理は失敗として扱い、次の起動で再試行する |
| 確定処理の途中でserveが終了した | 起動時に生音声ディレクトリから順番待ちを作り直す |
| 確定処理の結果を取り込む途中で終了した | 取り込みは何度行っても同じ結果になるため、もう一度取り込む |

## テスト

- **純粋な処理（TDD）**: anchorからの時刻計算（途切れ、ずれ、境界）、`.meta.jsonl`の読み書き、`SourceRecorder`のanchor判定、話者の割り当て（重なり、重なり無し、話者の切り替わり）、話者profileとの照合（閾値、1対1の割り当て）、`Reconciler.fold`の置き換え規則と過去の記録の互換、収録の一覧の差分読み込み、取り込みの冪等性
- **実機（CLI）**: `say -v Kyoko`と`say -v Otoya`を交互にsystem音声で流して停止し、`final.md`の話者が2人に分かれることを確かめる。収録中に`pmset displaysleepnow`で消灯し、点灯後にsystem音声の書き込みが再開することを確かめる。区切りの前後で`.pcm`の時刻が連続していることを確かめる。確定処理の途中で`serve`を終了させ、再起動後に確定が完了することを確かめる
- **実機（app）**: 確定後にライブパネルから話者に名前を付け、次の収録で同じ声に同じ名前が付くことを確かめる
- 各段階の終わりに`make verify`を通す

## 段階

段階ごとに実装計画を作る。段階1と段階2は同じbranchで続けて行い、実機で確かめてからmainへ入れる。段階1の途中では収録中の話者分離が無くなり、`final.md`に話者が付かない。段階2で確定処理が入って戻る。

| 段階 | 名前 | 内容 |
|---|---|---|
| 1 | 取り込みと生音声 | 生音声の新しい形式、`SourceRecorder`、取り込みの自動再開、区切りで止めない切り替え、望む状態と実状態のファイル、ライブの文字起こしの時刻、収録中の話者分離の撤去、再開位置の記録の撤去、メニューへの取り込みの状態の表示 |
| 2 | 確定処理 | `notetaked finalize`、順番待ちと取り込み、`SessionArchive`と`final.md`の生成の一本化、記録形式の変更、話者の識別、確定後の命名、生音声の削除、メニューへの確定の進捗の表示、整形を使える条件 |
| 3 | 構造の整理 | `PeerHub`への分割、`configure`コマンド、`AppModel`の分割、`DaemonClient`の読み込み、補助関数の統一、使われていないものとcommentの整理、エラーの扱い、`Reconciler`の速さ |
| 別spec | iPhoneとWatch | iPhone appとWatch appの整理 |

各段階で、README、HANDOFF、検証用skill（`verify`以外の`daemon-realtest`・`recordings`・`mac-app`）の記述を、その段階の動きに合わせて直す。
