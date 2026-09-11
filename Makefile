# Build a menu bar app out of a SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary; macOS wants a bundle before it will
# treat something as an app — an Info.plist with LSUIElement is what makes it
# a menu bar accessory with no Dock icon and no menu bar menus of its own.
# So the bundle is assembled here rather than in Xcode, which keeps the whole
# project a directory of text files.

APP     = AyeAye.app
BINARY  = .build/release/AyeAyeMenuBar
DEST    = $(APP)/Contents/MacOS/AyeAyeMenuBar

.PHONY: all build app install run check check-create clean

all: app

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BINARY) $(DEST)
	# Ad-hoc signing. Not notarisation and not a Developer ID — it is what
	# lets the Keychain hold an ACL for this binary at all, and what stops
	# Gatekeeper refusing an unsigned bundle outright on an Apple Silicon
	# machine. Each rebuild changes the signature, so the Keychain asks
	# again after one; "Always Allow" is per-binary, not per-app.
	codesign --force --sign - --identifier com.bitroot.ayeaye-menubar $(APP)
	@echo "Built $(APP) — open it, or 'make install' to put it in ~/Applications."

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/$(APP)
	cp -R $(APP) ~/Applications/
	@echo "Installed to ~/Applications/$(APP)."
	@echo "Add it in System Settings › General › Login Items to start it at login."

run: app
	open $(APP)

# The one thing here worth a test: that ⌘V works.
#
# It shipped broken — a menu bar app has no main menu, and AppKit implements
# paste as a main-menu key equivalent, so every text field silently refused
# to paste while accepting typing normally. That is invisible to a compiler
# and to any test that doesn't run a real event loop, which is why this one
# does: it starts the app, focuses a secure field, sends a real ⌘V through
# NSApp.sendEvent, and checks the token arrived. Needs a logged-in window
# server, so it is a `make check` rather than something a headless CI runs.
#
# It compiles the app's own EditMenu.swift, not a copy — a test of a replica
# would have passed against the broken app.
check:
	@swiftc Sources/AyeAyeMenuBar/EditMenu.swift Tests/PasteCheck/main.swift -o .build/pastecheck
	@./.build/pastecheck

# The other one: that a task with every optional field filled in arrives
# with every optional field filled in, that the box's other mode — a spark —
# is accepted and refused with a readable reason when it is empty, and that a
# timer can be started, read back and stopped.
#
# Separate from `check` because it needs a real installation and a write
# token, which it takes from the environment — the same three variables the
# scripted `--create` mode reads, so a dev stack costs nothing to point it at:
#
#   AYEAYE_SERVER=http://localhost AYEAYE_TOKEN=ayc_… AYEAYE_ORG=<uuid> make check-create
#
# Without them it skips — all but the pure parsing checks, which run either
# way. What it is really pinning is the parsing: most of this app's calls read
# prose written for a language model, and prose is a contract no compiler
# checks.
check-create:
	@swiftc Sources/AyeAyeMenuBar/MCPClient.swift Sources/AyeAyeMenuBar/Settings.swift \
		Tests/CreateCheck/main.swift -o .build/createcheck
	@./.build/createcheck

clean:
	rm -rf .build $(APP)
