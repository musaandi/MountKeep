.PHONY: build test install uninstall status mount-now logs

build:
	swift build -c release

test:
	swift test

install:
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

status:
	~/Applications/MountKeep.app/Contents/MacOS/MountKeep --status

mount-now:
	~/Applications/MountKeep.app/Contents/MacOS/MountKeep --mount-now

logs:
	tail -n 50 ~/Library/Logs/MountKeep.log
