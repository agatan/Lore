#!/bin/zsh
# LP (site/) に載せるスクリーンショットと動画を、demo dataの実画面から言語ごとに作り直す。
# 利用者データとは分離したin-memoryのdemo databaseだけを使う。画面収録は自process内のwindowだけ。
# 画面がロックされているとScreenCaptureKitが取り込みを始められないため、ロックを解除して実行する。
set -euo pipefail
cd "${0:A:h}/.."

APP_BIN="build/LoreUITests.app/Contents/MacOS/Lore"
OUT="site/assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LANGUAGES=(${=LORE_LP_LANGUAGES:-en ja zh-Hans})

locked="$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any]; print((d?["CGSSessionScreenIsLocked"] as? Bool) == true)' 2>/dev/null || echo false)"
if [[ "$locked" == "true" ]]; then
  echo "lp-media: the screen is locked. Unlock it and run again." >&2
  exit 1
fi

mkdir -p "$WORK/bin" "$OUT"
swiftc -O Scripts/patch-recording.swift -o "$WORK/bin/patch-recording" 2>/dev/null

run() { caffeinate -d -i "$APP_BIN" --lore-screenshot-demo "$@"; }
shot() { sips -Z "$3" "$1" --out "$2" >/dev/null; }
# crop <src> <dest> <x> <y> <width> <height> <max edge>: 3360x1920のmain window画像から、pixelで決めた範囲を切り出す。
crop() { sips -c "$6" "$5" --cropOffset "$4" "$3" "$1" --out "$2" >/dev/null; sips -Z "$7" "$2" >/dev/null; }

for lang in $LANGUAGES; do
  dest="$OUT/$lang"
  light="$WORK/$lang/light"; dark="$WORK/$lang/dark"; rec="$WORK/$lang/rec"
  mkdir -p "$dest" "$light" "$dark" "$rec"
  run --lore-demo-language "$lang" --lore-snapshot "$light" --lore-snapshot-appearance light
  run --lore-demo-language "$lang" --lore-snapshot "$dark" --lore-snapshot-appearance dark
  run --lore-demo-language "$lang" --lore-record "$rec" --lore-snapshot-appearance light
  for file in main-life-log.png main-life-log-paused.png main-history.png search.png life-log-mini.png menu-panel.png hud-recording.png settings-models.png; do
    [[ -f "$light/$file" ]] || { echo "lp-media: $lang: $file was not captured" >&2; exit 1; }
  done
  [[ -f "$rec/life-log.mp4" && -f "$rec/dictation.mp4" ]] || { echo "lp-media: $lang: recording failed" >&2; exit 1; }

  # 単独windowの収録ではsystemが信号機の位置へ収録中の印を描くため、静止画から戻す。
  # 最後の数字はposterに使う時点（秒）。
  "$WORK/bin/patch-recording" "$rec/life-log.mp4" "$dest/life-log.mp4" "$light/main-life-log.png" 0 0 420 110 1680 13.5
  "$WORK/bin/patch-recording" "$rec/dictation.mp4" "$dest/dictation.mp4" "$light/main-life-log.png" 0 0 0 0 1320 7.5

  shot "$dark/main-life-log.png" "$dest/life-log-dark.png" 2400
  shot "$light/main-history.png" "$dest/history.png" 2000
  shot "$dark/main-history.png" "$dest/history-dark.png" 2000
  shot "$light/search.png" "$dest/search.png" 1240
  shot "$light/life-log-mini.png" "$dest/mini.png" 920
  shot "$dark/life-log-mini.png" "$dest/mini-dark.png" 920
  shot "$light/menu-panel.png" "$dest/menu-panel.png" 840
  shot "$dark/menu-panel.png" "$dest/menu-panel-dark.png" 840
  shot "$light/hud-recording.png" "$dest/hud-recording.png" 1120
  shot "$light/settings-models.png" "$dest/settings-models.png" 1960
  crop "$light/main-life-log.png" "$dest/event-notes.png" 900 300 1500 540 1500
  crop "$light/main-life-log-paused.png" "$dest/paused.png" 940 1770 1440 140 1440
  [[ "$lang" == "en" ]] && cp "$light/menu-bar-icons.png" "$OUT/menu-bar-icons.png"
  echo "wrote $dest"
done

sips -s format png Resources/AppIcon.icns --out "$OUT/icon.png" >/dev/null
sips -Z 512 "$OUT/icon.png" >/dev/null
echo "wrote $OUT"
