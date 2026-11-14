#!/bin/zsh
set -euo pipefail

build_dir="$1"
contents="$2"
module_build="$build_dir/Lore.build"
if [[ ! -d "$module_build" ]]; then
    # Swift Build (Swift 6.4以降の既定)はintermediateをProductsと別の場所へ置く。
    module_build=".build/out/Intermediates.noindex/Lore.build/${(C)build_dir:t}"
fi
work_dir="$build_dir/Lore.appintents"
toolchain_dir="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
xcode_version="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
architecture="$(uname -m)"

mkdir -p "$work_dir"
find Sources/Lore -name '*.swift' -print > "$work_dir/sources.list"
find "$module_build" -name '*.swiftconstvalues' -print > "$work_dir/const-values.list"
: > "$work_dir/dependency-metadata.list"
: > "$work_dir/static-metadata.list"

"$toolchain_dir/usr/bin/appintentsmetadataprocessor" \
    --toolchain-dir "$toolchain_dir" \
    --module-name Lore \
    --sdk-root "$sdk_root" \
    --xcode-version "$xcode_version" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --bundle-identifier dev.agatan.Lore \
    --output "$contents/Resources" \
    --target-triple "$architecture-apple-macos26.0" \
    --binary-file "$contents/MacOS/Lore" \
    --source-file-list "$work_dir/sources.list" \
    --metadata-file-list "$work_dir/dependency-metadata.list" \
    --static-metadata-file-list "$work_dir/static-metadata.list" \
    --swift-const-vals-list "$work_dir/const-values.list" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization
