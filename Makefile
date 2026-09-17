# set DAEMON_IDENTITY=<SHA-1 of a valid "Apple Development" identity> once the certificate is renewed
DAEMON_IDENTITY ?= -
DERIVED := .build/DerivedData
LOGS := .build/logs
# compiler diagnostics with a file position; tool-level notices (e.g. AppIntents metadata) do not match
DIAG := '\.swift:[0-9]+:[0-9]+: (warning|error):'
# xcodebuild's own scheme-level failures (missing platform runtime, provisioning, etc.) are not
# compiler diagnostics and can occur even when xcodebuild's own exit code is unreliable (issue #10)
XCODEBUILD_ERROR := '^xcodebuild: error:'

SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c

.PHONY: test daemon project app verify clean

test:
	swift test

daemon:
	swift build -c release --product notetaked \
	  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/notetaked/Info.plist
	codesign --force --sign "$(DAEMON_IDENTITY)" --identifier io.github.bash0c7.notetaked .build/release/notetaked

project:
	cd Apps && xcodegen generate

app: daemon project
	xcodebuild -project Apps/Notetake.xcodeproj -scheme Notetake -configuration Debug -derivedDataPath $(DERIVED) build

# The single verification gate: every target compiles warning-free, all tests pass,
# the mac app builds, and the iOS app (with the embedded watch app) compiles without signing.
verify:
	mkdir -p $(LOGS)
	swift build 2>&1 | tee $(LOGS)/verify-build.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-build.log
	swift test 2>&1 | tee $(LOGS)/verify-test.log; test $${PIPESTATUS[0]} -eq 0
	$(MAKE) app 2>&1 | tee $(LOGS)/verify-app.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-app.log
	! grep -E $(XCODEBUILD_ERROR) $(LOGS)/verify-app.log
	xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'generic/platform=iOS' \
	  -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build 2>&1 | tee $(LOGS)/verify-ios.log; test $${PIPESTATUS[0]} -eq 0
	! grep -E $(DIAG) $(LOGS)/verify-ios.log
	! grep -E $(XCODEBUILD_ERROR) $(LOGS)/verify-ios.log
	@echo "verify: OK"

clean:
	rm -rf .build Apps/Notetake.xcodeproj
