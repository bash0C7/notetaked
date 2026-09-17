# ペアリングコード方式の代替 — 検討（issue #4）

親spec: `2026-09-12-notetake-design.md`（M5 iPhoneのペアリング・TLS PSK部分）。本specはissue #4の検討結果であり、**実装は含まない**（下記「このセッションで実装しない理由」参照）。

## 現状

- Mac appの設定Windowに6桁のペアリングコードが出る（`AppModel`が生成・保存、`serve --pair-code`で渡す）
- `PeerListener`（daemon）と`PeerClient`（iPhone）はどちらもこのコードをPSK（pre-shared key）としてTLS 1.2の`TLS_PSK_WITH_AES_128_GCM_SHA256`に使う（`sec_protocol_options_add_pre_shared_key`）
- 発見は`_notetake._tcp`のBonjour（`NWListener.Service` / `NWBrowser`）、到達性は`includePeerToPeer = true`（AWDL経由も含む）
- userの要望（issue本文）: 「ペアリングコード方式はやめれるかな？ icloudで同じログインがあるとか、そういうので識別できるといいな」

## 検討した案

### 案A: CloudKit private databaseに鍵レコードを置く

Mac appが起動時にランダムなPSKを生成し、userのiCloudアカウントのprivate CloudKit database（両appが同じiCloud containerを使う）に1レコードとして書く。iPhone appは同じcontainerから読み出して同じPSKでTLS接続する。

- 長所: 鍵自体はネットワーク越しに人手で入力しない。同じiCloudアカウントでサインインしている前提が自然に検証される（private databaseは同一iCloudアカウントの端末からしか読めない）
- 短所:
  - CloudKit containerの追加（`com.apple.developer.icloud-container-identifiers` entitlement、Xcode側でcontainer作成）。両ターゲット（`Notetake`/mac、`NotetakeMobile`/iOS、`NotetakeWatch`/watchOS）に同じcontainerとentitlementを付ける必要があり、`Apps/project.yml`のentitlements設定変更が要る
  - CloudKitの反映は同期であり即時ではない（push通知かpollingが要る）。Mac appを開いてすぐiPhoneでペアできない可能性がある
  - オフライン（iCloud未サインイン、機内モード等）では機能しない。現在のBonjour+PSK方式はローカルネットワークのみで完結しており、この点は後退になる
  - 実機・実iCloudアカウントでの検証が必須（このセッションでは不可能）

### 案B: `NSUbiquitousKeyValueStore`で鍵を配る

CloudKitより軽量な`NSUbiquitousKeyValueStore`（iCloud key-value storage、同一Apple ID・同一iCloud設定の端末間で自動同期）にPSKを1エントリとして置く。

- 長所: 案Aよりセットアップが軽い（専用CloudKit containerが不要、`com.apple.developer.ubiquity-kvstore-identifier` entitlementのみ）。同期の仕組みはOSに任せられる
- 短所: 案Aと同じく同期タイミングが非同期・不確定（`NSUbiquitousKeyValueStoreDidChangeExternallyNotification`を待つ必要がある）。容量制限（1MB、1キー最大1MB）は問題にならないが、同期の遅延・失敗時のfallbackが要る。iCloud未サインインでは動かない点も案Aと同じ
- 案Aとの比較: 鍵の配布だけが目的ならCloudKitのフルセットアップ（container・schema・push）は過剰で、案Bの方が変更量は小さい

### 案C（最小変更、issue本文が示唆する案）: 既存のBonjour+PSK経路は残し、鍵の生成・配布だけをiCloud経由にする

案A/Bのいずれかで生成した鍵を、現在ペアリングコード欄に手入力していた場所に自動で流し込む。TLS PSKの実装（`PeerListener`/`PeerClient`のTLS周り）自体は変更不要

- 案A/Bのどちらを使うかは、鍵配布だけなら`NSUbiquitousKeyValueStore`（案B）で十分という判断に至った

## 推奨（このspecの結論）

**案B（`NSUbiquitousKeyValueStore`による鍵配布）を、既存のBonjour+TLS PSK経路はそのまま残す形で採用する。** 理由:
- TLS PSKの実装（`PeerListener.makeParameters` / `PeerClient.connect`）は変更不要。「鍵をどう決めるか」だけを差し替える最小変更で済む
- CloudKit containerのセットアップ（案A）は今回のスコープに対して重い
- 手入力のペアリングコード欄は当面残し、iCloudキーが見つからない・iCloud未サインインの場合のfallbackとして使う（オフライン・非iCloud環境での動作を壊さない）

## 実装の入口（将来の実装時に着手する箇所）

- `Apps/project.yml`の`Notetake`（mac）・`NotetakeMobile`（iOS）両targetに`com.apple.developer.ubiquity-kvstore-identifier` entitlementを追加
- Mac app: `AppModel`起動時、`NSUbiquitousKeyValueStore.default`に既存のペアリングコード（またはランダム生成した鍵）が無ければ書き込み、あれば読み出して`serve --pair-code`に渡す
- iPhone app: `MobileModel`起動時、`NSUbiquitousKeyValueStore.default`からキーを読み出し、`NotificationCenter`で`NSUbiquitousKeyValueStoreDidChangeExternallyNotification`を購読して変化時に`PeerClient`を再接続する。取得できなければ現在の手入力欄にfallbackする
- 設定Windowの「ペアリングコード」セクションの文言を「自動（同じiCloudアカウント）/ 手動」の2モードに分け、iCloudキーが見つかった場合は手入力欄を隠すかグレーアウトする

## このセッションで実装しない理由

- iCloud key-value storeの同期挙動（反映タイミング、複数端末間の競合、iCloud未サインイン時の挙動）は実機・実Apple IDでしか確認できない。このセッション（Claude Code on the web、Linux、Swiftツールチェーン無し）ではコンパイルはおろかXcodeのentitlements設定すら検証できない
- entitlement追加はApple Developer Portalでのcapability有効化（CloudKit/iCloudのcontainer登録）を伴う可能性があり、Apple Developerアカウントの操作はuserの承認・実施が要る
- 上記のため、このissueは「検討・設計」で止め、実装はuserがMac側セッションで着手を判断してから行う
