.PHONY: run build test install release

run:
	scripts/build-app.sh Debug
	scripts/run-dev-app.sh ".build/AskKeyApp.app"

build:
	swift build -c release

test:
	swift test

install:
	scripts/build-app.sh Debug
	mkdir -p "$(HOME)/Applications"
	ditto .build/AskKeyApp.app "$(HOME)/Applications/Ask Key Dev.app"
	cp scripts/run-dev-app.sh "$(HOME)/Applications/Ask Key Dev.app/Contents/MacOS/AskKeyDevLauncher"
	chmod 755 "$(HOME)/Applications/Ask Key Dev.app/Contents/MacOS/AskKeyDevLauncher"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AskKeyDevLauncher" "$(HOME)/Applications/Ask Key Dev.app/Contents/Info.plist"
	codesign --force --deep --sign - "$(HOME)/Applications/Ask Key Dev.app"
	codesign --verify --strict --deep "$(HOME)/Applications/Ask Key Dev.app"

release:
	@scripts/release.sh $(TAG)
