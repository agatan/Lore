# Koe — build / bundle / run
#
# 権限 (マイク・アクセシビリティ) は .app に対して付与されるため、開発中も
# 常に `make run` で Koe.app を組み立てて起動する。素の実行ファイルでは
# CGEventTap もマイクも動かない。

CONFIG ?= debug
APP := build/Koe.app
CONTENTS := $(APP)/Contents
BUNDLE_ID := dev.agatan.Koe

# MLX の Metal シェーダは SwiftPM の CLI ビルドではコンパイルできない(mlx-swift の制約)。
# Metal ツールチェーンがあれば xcodebuild を使い、無ければ swift build で組む
# (その場合 MLX エンジンは選べない。UI 上でその理由を表示する)。
HAS_METAL := $(shell xcrun metal --version >/dev/null 2>&1 && echo yes)

# 署名 identity。「Koe Dev」があればそれを使う(make dev-cert で作れる)。
# 自己署名は信頼されない扱い(CSSMERR_TP_NOT_TRUSTED)なので find-identity に -v は付けない。
# ad-hoc 署名だとリビルドごとに identity が変わり、アクセシビリティの許可が毎回無効になる。
DEV_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -o "Koe Dev" | head -1)
CODESIGN_ID := $(if $(DEV_IDENTITY),Koe Dev,-)
XCCONFIG := $(shell [ "$(CONFIG)" = "release" ] && echo Release || echo Debug)
XCBUILD_DIR := .xcbuild/Build/Products/$(XCCONFIG)
SPM_BUILD_DIR := .build/$(CONFIG)
BUILD_DIR := $(if $(HAS_METAL),$(XCBUILD_DIR),$(SPM_BUILD_DIR))

.PHONY: all build app run stop test clean install icon metal-toolchain dev-cert reset-permissions

all: app

build:
ifeq ($(HAS_METAL),yes)
	xcodebuild -scheme Koe -destination 'platform=OS X' \
		-derivedDataPath .xcbuild -configuration $(XCCONFIG) build | \
		grep -E "error:|warning:|BUILD" || true
else
	@echo "note: Metal ツールチェーンが無いため MLX 無しでビルドします (make metal-toolchain)"
	swift build -c $(CONFIG) --product Koe
endif

## MLX を使うために Metal ツールチェーンを入れる (数 GB のダウンロード)
metal-toolchain:
	xcodebuild -downloadComponent MetalToolchain

## Koe.app を組み立てて署名する
app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/Koe" "$(CONTENTS)/MacOS/Koe"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@for b in $(BUILD_DIR)/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; \
	done
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
