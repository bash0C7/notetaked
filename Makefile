# set DAEMON_IDENTITY=<SHA-1 of a valid "Apple Development" identity> once the certificate is renewed
DAEMON_IDENTITY ?= -
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
