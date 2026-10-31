#!/bin/zsh
# Builds build/MacPopup.app. Usage: scripts/build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="build/MacPopup.app"
YOMITAN_COMMIT="d3c54c10264673eca0d66b970ef74cd5c8b048e3"

# Kanji stroke order font used by Yomitan's kanji entries (17 MB, so it's downloaded rather than vendored).
FONT="build/cache/kanji-stroke-orders.ttf"
if [[ ! -f "$FONT" ]]; then
    mkdir -p build/cache
    curl -fsSL -o "$FONT" \
        "https://raw.githubusercontent.com/yomidevs/yomitan/$YOMITAN_COMMIT/ext/data/fonts/kanji-stroke-orders.ttf" \
        || { echo "warning: couldn't download the kanji stroke order font; continuing without it"; rm -f "$FONT"; }
fi

(cd web && { [[ -d node_modules ]] || npm install --no-fund --no-audit; } && node build.mjs)

swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/MacPopup"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacPopup"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R build/web "$APP/Contents/Resources/web"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
