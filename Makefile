# Lore — build / bundle / run
#
# 権限 (マイク・アクセシビリティ) は .app に対して付与されるため、開発中も
# 常に `make run` で Lore.app を組み立てて起動する。素の実行ファイルでは
# CGEventTap もマイクも動かない。

CONFIG ?= debug
APP := build/Lore.app
CONTENTS := $(APP)/Contents
BUNDLE_ID := dev.agatan.Lore
UI_TEST_APP := build/LoreUITests.app
UI_TEST_BUNDLE_ID := dev.agatan.Lore.UIE2E

# 署名 identity。ShortcutsのApp Intentに必要なApple Developmentを優先する。
# なければ「Lore Dev」を使う(make dev-cert で作れる)。
# 自己署名は信頼されない扱い(CSSMERR_TP_NOT_TRUSTED)なので find-identity に -v は付けない。
# ad-hoc 署名だとリビルドごとに identity が変わり、アクセシビリティの許可が毎回無効になる。
APPLE_DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $$2; exit}')
DEV_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -o "Lore Dev" | head -1)
CODESIGN_ID := $(if $(APPLE_DEV_IDENTITY),$(APPLE_DEV_IDENTITY),$(if $(DEV_IDENTITY),Lore Dev,-))
BUILD_DIR = .build/$(CONFIG)
# SwiftPMはroot packageのartifactsをcheckout directory名(小文字)の下に置く。
WHISPER_FRAMEWORK = .build/artifacts/$(shell basename "$(CURDIR)" | tr A-Z a-z)/WhisperFramework/whisper.xcframework/macos-arm64_x86_64/whisper.framework

.PHONY: all build tools app ui-test-app run stop test ui-test clean install icon dev-cert reset-permissions lp-media

all: app

# 既定の推論はOS内蔵。クラウド／ローカルLLMもURLSessionだけで接続する。
# xcodebuild も Metal ツールチェーンも要らず、SwiftPM だけでビルドできる。
build:
	swift build -c $(CONFIG) --product Lore

## Shortcutsより細かい自動化向けのstdio MCPサーバー
tools:
	swift build -c $(CONFIG) --product lore-mcp
	@mkdir -p build/tools
	@cp "$(BUILD_DIR)/lore-mcp" build/tools/lore-mcp
	@echo "built build/tools/lore-mcp"

## Lore.app を組み立てて署名する
app: build tools
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Helpers" "$(CONTENTS)/Frameworks" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/Lore" "$(CONTENTS)/MacOS/Lore"
	@cp build/tools/lore-mcp "$(CONTENTS)/Helpers/lore-mcp"
	@cp -R "$(WHISPER_FRAMEWORK)" "$(CONTENTS)/Frameworks/whisper.framework"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp THIRD_PARTY_NOTICES "$(CONTENTS)/Resources/THIRD_PARTY_NOTICES.txt"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@for b in $(BUILD_DIR)/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; \
	done
	@for l in Sources/LoreKit/Resources/*.lproj; do \
		[ -e "$$l" ] && cp -R "$$l" "$(CONTENTS)/Resources/" || true; \
	done
	@zsh Scripts/extract-app-intents.sh "$(BUILD_DIR)" "$(CONTENTS)"
	@codesign --force --sign "$(CODESIGN_ID)" --timestamp=none \
		"$(CONTENTS)/Frameworks/whisper.framework"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID).mcp \
		--timestamp=none "$(CONTENTS)/Helpers/lore-mcp"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID) \
		--timestamp=none "$(APP)" 2>/dev/null \
		|| codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID) "$(APP)"
	@echo "built $(APP) (signed with: $(CODESIGN_ID))"
ifeq ($(CODESIGN_ID),-)
	@echo "note: ad-hoc 署名です。リビルドごとにアクセシビリティの許可が外れます → make dev-cert"
endif

## 本番Loreとbundle ID、UserDefaults、process instanceを共有しないUI E2E専用app
ui-test-app: app
	@rm -rf "$(UI_TEST_APP)"
	@cp -R "$(APP)" "$(UI_TEST_APP)"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(UI_TEST_BUNDLE_ID)" "$(UI_TEST_APP)/Contents/Info.plist"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(UI_TEST_BUNDLE_ID) \
		--timestamp=none "$(UI_TEST_APP)" 2>/dev/null \
		|| codesign --force --sign "$(CODESIGN_ID)" --identifier $(UI_TEST_BUNDLE_ID) "$(UI_TEST_APP)"
	@echo "built $(UI_TEST_APP) (signed with: $(CODESIGN_ID))"

## 起動中の Lore を落としてから再起動する
run: stop app
	@open "$(APP)"
	@echo "Lore を起動しました (メニューバーを確認)"

stop:
	@pkill -x Lore >/dev/null 2>&1 || true

test:
	swift test

## 署名済みアプリを実際に操作する主要CUJのUI E2E
ui-test: ui-test-app
	@mkdir -p .build/ui-e2e
	@xcrun swiftc -parse-as-library Scripts/LoreUIE2E.swift -o .build/ui-e2e/LoreUIE2E
	@.build/ui-e2e/LoreUIE2E "$(abspath $(UI_TEST_APP))"

clean:
	rm -rf .build build

## /Applications へ配置する (権限を安定させたい場合)
## bundle ID が同じコピーが複数あると TCC が混乱するので、build/ のコピーは残さない
install: CONFIG = release
install: app
	@pkill -x Lore >/dev/null 2>&1 || true
	@rm -rf /Applications/Lore.app
	@cp -R "$(APP)" /Applications/
	@rm -rf "$(APP)"
	@echo "installed /Applications/Lore.app"
	@open /Applications/Lore.app

## 署名 identity を固定してアクセシビリティの許可が毎回外れないようにする (一度だけ)
dev-cert:
	@bash Scripts/make-dev-cert.sh

## 権限の登録をリセットする (許可が壊れて有効にできないとき)
reset-permissions: stop
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@tccutil reset Microphone $(BUNDLE_ID) || true
	@tccutil reset ListenEvent $(BUNDLE_ID) 2>/dev/null || true
	@echo "リセットしました。起動して許可し直してください。"

## LP (site/) のスクリーンショットと動画をdemo dataから作り直す
lp-media: ui-test-app
	@zsh Scripts/lp-media.sh

## Resources/AppIcon.icns を生成する
icon:
	@swift Scripts/make-icon.swift
