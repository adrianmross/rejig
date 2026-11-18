APP := build/Tilespace.app
# A real identity keeps the Accessibility grant across rebuilds; ad-hoc ("-")
# signatures change with every build and macOS asks again.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $$2; exit}')

.PHONY: app test install uninstall clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/tilespace $(APP)/Contents/MacOS/tilespace
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(if $(SIGN_ID),$(SIGN_ID),-)" $(APP)

test:
	swift test

install: app
	-pkill -x tilespace
	mkdir -p ~/Applications
	rm -rf ~/Applications/Tilespace.app
	cp -R $(APP) ~/Applications/
	mkdir -p ~/.local/bin
	ln -sf ~/Applications/Tilespace.app/Contents/MacOS/tilespace ~/.local/bin/tilespace
	open ~/Applications/Tilespace.app

uninstall:
	-pkill -x tilespace
	rm -rf ~/Applications/Tilespace.app ~/.local/bin/tilespace
	-tccutil reset Accessibility com.adrianmross.tilespace

clean:
	rm -rf .build build
