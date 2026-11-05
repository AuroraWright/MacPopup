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

# libcurl-impersonate, for the cloud OCR engines' requests (Sources/CurlImpersonate): a release of
# github.com/lexiforest/curl-impersonate, checked against its SHA-256.
CURL_IMPERSONATE_VERSION="v2.2.3"
case "$(uname -m)" in
    arm64) CURL_IMPERSONATE_ARCH=arm64 CURL_IMPERSONATE_SHA256=16a73c8dfc55cb8c2354f93f43525529d0df6cbfc484fb7a4357b3891f9dbb6a ;;
    *) CURL_IMPERSONATE_ARCH=x86_64 CURL_IMPERSONATE_SHA256=32634096e31e879d0a193f87e4a4083e2eb44b9b9318eb5b32f85f495104a049 ;;
esac
CURL_IMPERSONATE="build/cache/libcurl-impersonate-$CURL_IMPERSONATE_VERSION-$CURL_IMPERSONATE_ARCH"
# (libcurl-impersonate.4.dylib is a link to the file with the full version.)
if [[ ! -f "$CURL_IMPERSONATE/libcurl-impersonate.4.dylib" ]]; then
    ARCHIVE="build/cache/libcurl-impersonate-$CURL_IMPERSONATE_VERSION.$CURL_IMPERSONATE_ARCH-macos.tar.gz"
    mkdir -p build/cache
    if curl -fsSL -o "$ARCHIVE" \
        "https://github.com/lexiforest/curl-impersonate/releases/download/$CURL_IMPERSONATE_VERSION/libcurl-impersonate-$CURL_IMPERSONATE_VERSION.$CURL_IMPERSONATE_ARCH-macos.tar.gz" \
        && [[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$CURL_IMPERSONATE_SHA256" ]]; then
        rm -rf "$CURL_IMPERSONATE"
        mkdir -p "$CURL_IMPERSONATE"
        tar -xzf "$ARCHIVE" -C "$CURL_IMPERSONATE" 'libcurl-impersonate.4*.dylib' 'LICENSE*'
    else
        echo "warning: couldn't download libcurl-impersonate; Google Lens and Bing won't work"
    fi
    rm -f "$ARCHIVE"
fi

swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/MacPopup" "$APP/Contents/MacOS/MacPopup"
# The Yomitan API's native messaging host, which Settings → Scanning → Install copies next to a browser's manifest.
cp "$BIN_DIR/yomitan-api" "$APP/Contents/Helpers/yomitan_api"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R build/web "$APP/Contents/Resources/web"
if [[ -f "$CURL_IMPERSONATE/libcurl-impersonate.4.dylib" ]]; then
    mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses/curl-impersonate"
    cp -L "$CURL_IMPERSONATE/libcurl-impersonate.4.dylib" "$APP/Contents/Frameworks/"
    cp "$CURL_IMPERSONATE"/LICENSE* "$APP/Contents/Resources/Licenses/curl-impersonate/"
fi
# meikiocr's and PP-OCRv6_manga's models (see vendor/meikiocr and vendor/ppocr-manga), compiled for Core ML.
mkdir -p "$APP/Contents/Resources/Models"
for model in vendor/meikiocr/*.mlpackage vendor/ppocr-manga/*.mlpackage; do
    xcrun coremlcompiler compile "$model" "$APP/Contents/Resources/Models" >/dev/null
done
cp vendor/ppocr-manga/PPOCRMangaCharacters.txt "$APP/Contents/Resources/Models/"
# Signed with a certificate, macOS keeps the privacy permissions (Screen Recording, Microphone,
# Accessibility) across builds; ad-hoc signatures change with every build, so they'd be asked for again.
# MACPOPUP_SIGN_IDENTITY overrides the identity ("-" for ad-hoc).
IDENTITY="${MACPOPUP_SIGN_IDENTITY:-Apple Development: Your Name (TEAMID)}"
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "warning: no code signing identity \"$IDENTITY\"; signing ad-hoc (permissions will be asked for again)"
    IDENTITY="-"
fi
# Nested code is signed first.
if [[ -d "$APP/Contents/Frameworks" ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"/Contents/Frameworks/*.dylib >/dev/null
fi
codesign --force --timestamp=none --sign "$IDENTITY" --identifier local.macpopup.yomitan-api "$APP/Contents/Helpers/yomitan_api" >/dev/null
codesign --force --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null

echo "Built $APP"
