#!/bin/bash
# usage: install.sh iphone|watch   — 実機向けにbuildしてdevicectlでインストールする
# iPhoneはロック解除、Watchはロック解除 + Mac近接（トンネルが張れないとタイムアウト）
set -eo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd); cd "$ROOT"
IPHONE=FE7B47C9-2CF0-5509-A52C-1C0D806CC085
WATCH=4583DD30-701C-5787-8BAC-600F4F495DEA
DD=.build/DerivedData-device
case "$1" in
  iphone) SCHEME=NotetakeMobile; DEV=$IPHONE; APP=$DD/Build/Products/Debug-iphoneos/NotetakeMobile.app ;;
  watch)  SCHEME=NotetakeWatch;  DEV=$WATCH;  APP=$DD/Build/Products/Debug-watchos/NotetakeWatch.app ;;
  *) echo "usage: $0 iphone|watch"; exit 2 ;;
esac
[ -d Apps/Notetake.xcodeproj ] || make project
xcodebuild -project Apps/Notetake.xcodeproj -scheme $SCHEME -destination "id=$DEV" -derivedDataPath $DD \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 | tee .build/logs/device-build-$1.log | tail -n 3
xcrun devicectl device install app --device $DEV "$APP" 2>&1 | tail -n 3
