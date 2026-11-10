#!/bin/zsh
# Builds build/MacPopup.app. Usage: scripts/build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
    echo "error: MacPopup is built on and for Apple Silicon Macs" >&2
    exit 1
fi
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
CURL_IMPERSONATE_SHA256=16a73c8dfc55cb8c2354f93f43525529d0df6cbfc484fb7a4357b3891f9dbb6a
CURL_IMPERSONATE="build/cache/libcurl-impersonate-$CURL_IMPERSONATE_VERSION-arm64"
# (libcurl-impersonate.4.dylib is a link to the file with the full version.)
if [[ ! -f "$CURL_IMPERSONATE/libcurl-impersonate.4.dylib" ]]; then
    ARCHIVE="build/cache/libcurl-impersonate-$CURL_IMPERSONATE_VERSION.arm64-macos.tar.gz"
    mkdir -p build/cache
    if curl -fsSL -o "$ARCHIVE" \
        "https://github.com/lexiforest/curl-impersonate/releases/download/$CURL_IMPERSONATE_VERSION/libcurl-impersonate-$CURL_IMPERSONATE_VERSION.arm64-macos.tar.gz" \
        && [[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$CURL_IMPERSONATE_SHA256" ]]; then
        rm -rf "$CURL_IMPERSONATE"
        mkdir -p "$CURL_IMPERSONATE"
        tar -xzf "$ARCHIVE" -C "$CURL_IMPERSONATE" 'libcurl-impersonate.4*.dylib' 'LICENSE*'
    else
        echo "warning: couldn't download libcurl-impersonate; Google Lens and Bing won't work"
    fi
    rm -f "$ARCHIVE"
fi

# A small ffmpeg for the sentence audio and screenshots of video players' lines (iina-plugin/), built from the
# source releases of FFmpeg and dav1d, checked against their SHA-256 (scripts/build-ffmpeg.sh; a few minutes the
# first time).
FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D_VERSION="1.5.4"
DAV1D_SHA256=2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
FFMPEG="build/cache/ffmpeg-$FFMPEG_VERSION-dav1d-$DAV1D_VERSION-arm64"
if [[ ! -x "$FFMPEG/ffmpeg" ]]; then
    scripts/build-ffmpeg.sh "$FFMPEG_VERSION" "$FFMPEG_SHA256" "$DAV1D_VERSION" "$DAV1D_SHA256" "$FFMPEG" \
        || echo "warning: couldn't build ffmpeg; lines from IINA won't have sentence audio or their own screenshots"
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
if [[ -x "$FFMPEG/ffmpeg" ]]; then
    mkdir -p "$APP/Contents/Resources/Licenses/ffmpeg"
    cp "$FFMPEG/ffmpeg" "$APP/Contents/Helpers/ffmpeg"
    cp "$FFMPEG"/COPYING.* "$FFMPEG"/LICENSE.md "$FFMPEG"/SOURCE.txt "$APP/Contents/Resources/Licenses/ffmpeg/"
fi
# The IINA plugin (iina-plugin/), packaged for IINA to install when it's opened.
(cd iina-plugin && zip -q -r -X "../$APP/Contents/Resources/MacPopup.iinaplgz" Info.json main.js global.js preferences.html)
# meikiocr's and PP-OCRv6_manga's models (see vendor/meikiocr and vendor/ppocr-manga), compiled for Core ML.
mkdir -p "$APP/Contents/Resources/Models"
for model in vendor/meikiocr/*.mlpackage vendor/ppocr-manga/*.mlpackage; do
    xcrun coremlcompiler compile "$model" "$APP/Contents/Resources/Models" >/dev/null
done
cp vendor/ppocr-manga/PPOCRMangaCharacters.txt "$APP/Contents/Resources/Models/"
# Signed with a certificate, macOS keeps the privacy permissions (Screen Recording, Accessibility) across
# builds; ad-hoc signatures change with every build, so they'd be asked for again.
# The certificate is MACPOPUP_SIGN_IDENTITY, or else the first line of .signing-identity (kept out of git), such as
# "Apple Development: Your Name (TEAMID)". Without either, or with "-", the app is signed ad-hoc.
IDENTITY="${MACPOPUP_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then
    IDENTITY="$(head -n 1 .signing-identity)"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "note: no code signing identity set (MACPOPUP_SIGN_IDENTITY or .signing-identity); signing ad-hoc"
    IDENTITY="-"
elif [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "warning: no code signing identity \"$IDENTITY\"; signing ad-hoc (permissions will be asked for again)"
    IDENTITY="-"
fi
# Nested code is signed first.
if [[ -d "$APP/Contents/Frameworks" ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"/Contents/Frameworks/*.dylib >/dev/null
fi
codesign --force --timestamp=none --sign "$IDENTITY" --identifier local.macpopup.yomitan-api "$APP/Contents/Helpers/yomitan_api" >/dev/null
if [[ -f "$APP/Contents/Helpers/ffmpeg" ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" --identifier local.macpopup.ffmpeg "$APP/Contents/Helpers/ffmpeg" >/dev/null
fi
codesign --force --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null

echo "Built $APP"
