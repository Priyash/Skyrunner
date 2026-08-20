# SkyRunner — everything you need to build, test and run the game.
#
#   make            what each target does
#   make project    generate SkyRunner.xcodeproj from project.yml
#   make build      compile for the simulator
#   make test       run the unit suites
#   make run        boot a simulator, install, launch
#   make verify     the offline checks: assets, level rules, rig data
#   make editor     open the level and rig editors with the AI bridge running
#
# The project file is generated, not checked in: `project.yml` is the source of
# truth, so adding a Swift file needs no project edit and no merge conflict.

SHELL := /bin/bash
PROJECT   := SkyRunner.xcodeproj
SCHEME    := SkyRunner
# iPhone and iPad only — see project.yml. `make devices` lists what is bootable.
SIMULATOR ?= iPhone 16 Pro
CONFIG    ?= Debug
BUNDLE_ID := com.skyrunner.game
PYTHON    := $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || echo python3)

# Xcode.app rather than whatever `xcode-select` happens to point at. A machine
# set up for command-line work often points at CommandLineTools, which has no
# iOS SDK, and the resulting error names the wrong cause.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG)
DEST := -destination 'platform=iOS Simulator,name=$(SIMULATOR)'
# `xcbeautify`/`xcpretty` when available, otherwise the raw log filtered to the
# lines that matter. A wall of build output hides the one error in it.
FILTER := $(shell command -v xcbeautify >/dev/null && echo 'xcbeautify' || \
            (command -v xcpretty >/dev/null && echo 'xcpretty' || \
             echo "grep -E 'error:|warning:|Test Case|Executed|BUILD|TEST|\*\*' || true"))

.DEFAULT_GOAL := help
.PHONY: help doctor project build test run clean verify audit levels index editor art audio atlas terrain props themes cook archive ci

help:
	@echo "SkyRunner"
	@echo "  make doctor    check the toolchain is usable (start here)"
	@echo "  make project   generate $(PROJECT) from project.yml"
	@echo "  make build     compile for the '$(SIMULATOR)' simulator"
	@echo "  make test      run the unit suites"
	@echo "  make run       install and launch on the simulator"
	@echo "  make verify    offline content checks (no Xcode needed)"
	@echo "  make levels    list the level files the game will load, in order"
	@echo "  make index     regenerate the launch-time level index"
	@echo "  make editor    level + rig editors, with the AI bridge on :8787"
	@echo "  make art       regenerate the hero and the backdrop"
	@echo "  make audio     regenerate every sound effect and music track"
	@echo "  make atlas     pack rig art into one texture page (7 binds → 1)"
	@echo "  make terrain   regenerate the tiling terrain textures for frises"
	@echo "  make props     regenerate the backdrop props (trunks, rocks, ferns)"
	@echo "  make themes    every theme: props, terrain surfaces and a backdrop"
	@echo "  make cook      validate + pack + manifest + budget the content"
	@echo "  make archive   Release archive (needs SKYRUNNER_TEAM=<teamid>)"
	@echo "  make ci        cook + build + test, the gate before pushing"
	@echo "  make clean     remove build products and the generated project"
	@echo ""
	@echo "  SIMULATOR='iPad Pro 13-inch (M4)' make run     pick a device"
	@echo "  CONFIG=Release make build                      optimised build"

# ── toolchain ───────────────────────────────────────────────────────────────
doctor:
	@echo "Xcode:      $$(DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -version 2>/dev/null \
	    | head -1 || echo 'not found')"
	@# `xcodebuild -version` answers even when the licence has not been accepted,
	@# so probe something that needs the SDK. Otherwise doctor reports a healthy
	@# toolchain and the first real build fails with an unrelated-looking error.
	@if ! DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphonesimulator \
	        --show-sdk-path >/dev/null 2>&1; then \
	    echo "iOS SDK:    NOT USABLE"; \
	    echo ""; \
	    echo "  Xcode is installed but not set up. One-time, needs sudo:"; \
	    echo "    sudo xcode-select -s $(DEVELOPER_DIR)"; \
	    echo "    sudo xcodebuild -license accept"; \
	    echo "    xcodebuild -downloadPlatform iOS   # if no simulator runtime"; \
	    echo ""; \
	    echo "  Until then 'make verify' still works — it needs no Xcode."; \
	    exit 1; \
	fi
	@echo "iOS SDK:    $$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null)"
	@echo "Python:     $$($(PYTHON) --version 2>&1)"
	@echo "Pillow:     $$($(PYTHON) -c 'import PIL; print(PIL.__version__)' 2>/dev/null \
	    || echo 'missing — art generation disabled, engine unaffected')"
	@echo "XcodeGen:   $$(command -v xcodegen >/dev/null && xcodegen --version \
	    || echo 'not installed — using the bundled generator')"
	@echo "Simulators: $$(xcrun simctl list devices available 2>/dev/null \
	    | grep -cE 'iPhone|iPad'; true) available"

# ── project generation ──────────────────────────────────────────────────────
# XcodeGen when it's there, the bundled generator otherwise. Both read the same
# project.yml, so "I don't have brew" is never a reason you can't build.
# Always regenerated rather than timestamp-guarded. Both generators are
# deterministic — object ids are hashes of what they identify, so an unchanged
# project comes out byte-identical — and the alternative is the trap where a
# newly added file is silently absent because its mtime predates the project.
project:
	@if command -v xcodegen >/dev/null 2>&1; then \
	    echo "→ xcodegen"; xcodegen generate --quiet; \
	else \
	    echo "→ bundled generator (Tools/genproject.py)"; \
	    $(PYTHON) Tools/genproject.py; \
	fi

# ── build / test / run ──────────────────────────────────────────────────────
build: project
	set -o pipefail; $(XCB) $(DEST) build 2>&1 | $(FILTER)

test: project
	set -o pipefail; $(XCB) $(DEST) test 2>&1 | $(FILTER)

run: build
	@echo "→ booting $(SIMULATOR)"
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	@open -a Simulator
	@APP=$$($(XCB) $(DEST) -showBuildSettings 2>/dev/null \
	    | awk '/ BUILT_PRODUCTS_DIR =/ {print $$3}' | head -1)/$(SCHEME).app; \
	 echo "→ installing $$APP"; \
	 xcrun simctl install booted "$$APP" && \
	 xcrun simctl launch booted $(BUNDLE_ID)

clean:
	rm -rf $(PROJECT) build
	@DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project $(PROJECT) clean \
	    >/dev/null 2>&1 || true
	@echo "cleaned"

# ── content checks that need no Xcode ───────────────────────────────────────
# These are the same rules the Swift suites assert, run against the files on
# disk. They finish in about a second, so they are the fast inner loop while
# authoring levels or art.
verify: audit
	@echo "── level index ──"
	@$(PYTHON) Tools/level_index.py --check
	@echo "── levels ──"
	@$(PYTHON) Tools/ai_director.py validate --all
	@echo "── rig data ──"
	@$(PYTHON) Tools/asset_audit.py --strict >/dev/null && echo "rig + backdrop ok"

audit:
	@echo "── assets ──"
	@$(PYTHON) Tools/asset_audit.py

levels:
	@$(PYTHON) Tools/ai_director.py levels

# The gate. `verify` first because it is a second and catches content problems
# that would otherwise surface as a confusing test failure ten minutes later.
ci: cook build test
	@echo ""
	@echo "✓ content cooked and inside budget, project builds, suites pass"

# ── authoring ───────────────────────────────────────────────────────────────
editor:
	@echo "→ AI bridge on http://127.0.0.1:8787 (ctrl-C to stop)"
	@open Tools/LevelEditor.html Tools/RigEditor.html
	@$(PYTHON) Tools/ai_director.py serve

# Regenerates both halves of the shipped content into the folders the bundle
# reads, then re-audits — because the audit is what catches the mistake that
# matters here (art whose declared size no longer matches its pixels).
art:
	$(PYTHON) Tools/art_director.py --default hero --preview --out Assets/Rigs
	$(PYTHON) Tools/art_director.py Assets/Friezes/forest_backdrop.spec.json \
	    --out Assets/Friezes
	@$(MAKE) --no-print-directory atlas

# Every effect and track, synthesized from scratch — no samples, so the whole set
# is reproducible and a new sound is a few lines of parameters.
audio:
	$(PYTHON) Tools/audio_director.py
	@$(MAKE) --no-print-directory audit

# One page instead of seven textures. Untrimmed on purpose — `PackedAtlas` uses
# sub-rects as drop-in replacements and refuses a trimmed page rather than
# mis-drawing it.
atlas:
	$(PYTHON) Tools/atlas_packer.py Assets/Rigs Assets/Rigs/hero_atlas --size 1024
	@$(MAKE) --no-print-directory audit

terrain:
	$(PYTHON) -c "import sys; sys.path.insert(0, 'Tools'); import art_director as a; \
	    w, p = a.build_terrain('Assets/Terrain'); print(len(w), 'file(s)'); \
	    [print('  ✗', x) for x in p]"
	@$(MAKE) --no-print-directory audit

props:
	$(PYTHON) -c "import sys; sys.path.insert(0, 'Tools'); import art_director as a; \
	    w, p = a.build_props('Assets/Friezes'); print(len(w), 'file(s)'); \
	    [print('  ✗', x) for x in p]"
	@$(MAKE) --no-print-directory audit

# The content pipeline: what turns edited files into shippable bytes, with a
# budget that fails the build rather than a size nobody watches.
# Every theme's complete asset set. `make themes THEME=jungle` for just one.
themes:
	$(PYTHON) -c "import sys; sys.path.insert(0, 'Tools'); import art_director as a; \
	    names = ['$(THEME)'] if '$(THEME)' else sorted(a.THEMES); \
	    [print(n, len(a.build_theme(n, 'Assets/Friezes', 'Assets/Terrain')[0]), \
	           'files', a.build_theme(n, 'Assets/Friezes', 'Assets/Terrain')[1] or '') \
	     for n in names]"
	@$(MAKE) --no-print-directory audit

# The level index: one file the game reads at launch instead of decoding every level.
index:
	$(PYTHON) Tools/level_index.py

cook:
	$(PYTHON) Tools/level_index.py
	$(PYTHON) Tools/cook.py --stamp "$(shell git rev-parse --short HEAD 2>/dev/null)"

# Device archive. Signing is off by default so a clean machine can build for the
# simulator; a team switches it on without editing project.yml.
archive: project
	@if [ -z "$(SKYRUNNER_TEAM)" ]; then \
	    echo "archive needs a signing team:  SKYRUNNER_TEAM=ABCDE12345 make archive"; \
	    exit 1; \
	fi
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	    -configuration Release -destination 'generic/platform=iOS' \
	    -archivePath build/SkyRunner.xcarchive \
	    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
	    DEVELOPMENT_TEAM=$(SKYRUNNER_TEAM) archive 2>&1 | $(FILTER)
