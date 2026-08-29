# Koe — build / bundle / run
#
# 権限 (マイク・アクセシビリティ) は .app に対して付与されるため、開発中も
# 常に `make run` で Koe.app を組み立てて起動する。素の実行ファイルでは
# CGEventTap もマイクも動かない。

CONFIG ?= debug
APP := build/Koe.app
CONTENTS := $(APP)/Contents
BUNDLE_ID := dev.agatan.Koe

# 署名 identity。「Koe Dev」があればそれを使う(make dev-cert で作れる)。
# 自己署名は信頼されない扱い(CSSMERR_TP_NOT_TRUSTED)なので find-identity に -v は付けない。
# ad-hoc 署名だとリビルドごとに identity が変わり、アクセシビリティの許可が毎回無効になる。
DEV_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -o "Koe Dev" | head -1)
CODESIGN_ID := $(if $(DEV_IDENTITY),Koe Dev,-)
BUILD_DIR = .build/$(CONFIG)

.PHONY: all build tools app run stop test ui-test clean install icon dev-cert reset-permissions

all: app

# 既定の推論はOS内蔵。クラウド／ローカルLLMもURLSessionだけで接続する。
# xcodebuild も Metal ツールチェーンも要らず、SwiftPM だけでビルドできる。
build:
	swift build -c $(CONFIG) --product Koe

## Shortcutsより細かい自動化向けのCLIとstdio MCPサーバー
tools:
	swift build -c $(CONFIG) --product koe-cli
	swift build -c $(CONFIG) --product koe-mcp
	@mkdir -p build/tools
	@cp "$(BUILD_DIR)/koe-cli" build/tools/koe
	@cp "$(BUILD_DIR)/koe-mcp" build/tools/koe-mcp
	@echo "built build/tools/koe and build/tools/koe-mcp"

## Koe.app を組み立てて署名する
app: build tools
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Helpers" "$(CONTENTS)/Resources/Skills"
	@cp "$(BUILD_DIR)/Koe" "$(CONTENTS)/MacOS/Koe"
	@cp build/tools/koe "$(CONTENTS)/Helpers/koe"
	@cp build/tools/koe-mcp "$(CONTENTS)/Helpers/koe-mcp"
	@cp -R Resources/Skills/koe "$(CONTENTS)/Resources/Skills/koe"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp THIRD_PARTY_NOTICES "$(CONTENTS)/Resources/THIRD_PARTY_NOTICES.txt"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@for b in $(BUILD_DIR)/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; \
	done
	@zsh Scripts/extract-app-intents.sh "$(BUILD_DIR)" "$(CONTENTS)"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID).cli \
		--timestamp=none "$(CONTENTS)/Helpers/koe"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID).mcp \
		--timestamp=none "$(CONTENTS)/Helpers/koe-mcp"
	@codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID) \
		--timestamp=none "$(APP)" 2>/dev/null \
		|| codesign --force --sign "$(CODESIGN_ID)" --identifier $(BUNDLE_ID) "$(APP)"
	@echo "built $(APP) (signed with: $(CODESIGN_ID))"
ifeq ($(CODESIGN_ID),-)
	@echo "note: ad-hoc 署名です。リビルドごとにアクセシビリティの許可が外れます → make dev-cert"
endif

## 起動中の Koe を落としてから再起動する
run: stop app
	@open "$(APP)"
	@echo "Koe を起動しました (メニューバーを確認)"

stop:
	@pkill -x Koe >/dev/null 2>&1 || true

test:
	swift test

## 署名済みアプリを実際に操作する主要CUJのUI E2E
ui-test: stop app
	@mkdir -p .build/ui-e2e
	@xcrun swiftc -parse-as-library Scripts/KoeUIE2E.swift -o .build/ui-e2e/KoeUIE2E
	@.build/ui-e2e/KoeUIE2E "$(abspath $(APP))"

clean:
	rm -rf .build build

## /Applications へ配置する (権限を安定させたい場合)
## bundle ID が同じコピーが複数あると TCC が混乱するので、build/ のコピーは残さない
install: CONFIG = release
install: stop app
	@rm -rf /Applications/Koe.app
	@cp -R "$(APP)" /Applications/
	@rm -rf "$(APP)"
	@echo "installed /Applications/Koe.app"
	@open /Applications/Koe.app

## 署名 identity を固定してアクセシビリティの許可が毎回外れないようにする (一度だけ)
dev-cert:
	@bash Scripts/make-dev-cert.sh

## 権限の登録をリセットする (許可が壊れて有効にできないとき)
reset-permissions: stop
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@tccutil reset Microphone $(BUNDLE_ID) || true
	@tccutil reset ListenEvent $(BUNDLE_ID) 2>/dev/null || true
	@echo "リセットしました。起動して許可し直してください。"

## Resources/AppIcon.icns を生成する
icon:
	@swift Scripts/make-icon.swift
