APP := build/Rejig.app
# A real identity keeps the Accessibility grant across rebuilds; ad-hoc ("-")
# signatures change with every build and macOS asks again.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $$2; exit}')

.PHONY: app test install uninstall clean icon notarize

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/rejig $(APP)/Contents/MacOS/rejig
	cp Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	cp Resources/AppIcon.icns Resources/Assets.car $(APP)/Contents/Resources/
	codesign --force --options runtime --sign "$(if $(SIGN_ID),$(SIGN_ID),-)" $(APP)

# Redraws the icon's layers from Scripts/icon.swift and compiles Resources/AppIcon.icon
# (an Icon Composer document) into Assets.car, plus AppIcon.icns for macOS before 26.
icon:
	mkdir -p build
	swift Scripts/icon.swift Resources/AppIcon.icon/Assets/front.png front
	swift Scripts/icon.swift Resources/AppIcon.icon/Assets/under.png under
	xcrun actool Resources/AppIcon.icon --compile Resources --app-icon AppIcon --platform macosx \
		--minimum-deployment-target 13.0 --output-partial-info-plist build/icon.plist >/dev/null

# For sharing: Apple checks the build so Gatekeeper opens it on other Macs.
# Credentials: a keychain profile (once: xcrun notarytool store-credentials rejig --team-id <team>),
# or an App Store Connect key: make notarize NOTARY="--key <p8> --key-id <id> --issuer <uuid>"
NOTARY ?= --keychain-profile rejig
notarize: app
	ditto -c -k --keepParent $(APP) build/Rejig.zip
	xcrun notarytool submit build/Rejig.zip $(NOTARY) --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) build/Rejig.zip

test:
	swift test

install: app
	-pkill -x rejig && sleep 1
	mkdir -p ~/Applications
	rm -rf ~/Applications/Rejig.app
	cp -R $(APP) ~/Applications/
	mkdir -p ~/.local/bin
	ln -sf ~/Applications/Rejig.app/Contents/MacOS/rejig ~/.local/bin/rejig
	open ~/Applications/Rejig.app

uninstall:
	-pkill -x rejig && sleep 1
	-tccutil reset Accessibility com.adrianmross.rejig
	rm -rf ~/Applications/Rejig.app ~/.local/bin/rejig

clean:
	rm -rf .build build
