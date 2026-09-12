DAEMON_IDENTITY ?= $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep 'Apple Development' | head -1 | awk '{print $$2}')
DERIVED := .build/DerivedData

.PHONY: test daemon project app clean

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

clean:
	rm -rf .build Apps/Notetake.xcodeproj
