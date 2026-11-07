#!/bin/sh
# Xcode build phase: puts libcurl-impersonate (Google Lens' and Bing's requests, see
# Sources/OCREngines/ImpersonatedSession.swift) in the app as libcurl-impersonate.framework, since iOS only loads signed
# libraries from frameworks in the app. It's the release of github.com/lexiforest/curl-impersonate for iOS, the version
# scripts/build.sh puts in the Mac app, checked against its SHA-256 and kept in build/cache.
set -eu

VERSION="v2.2.3"
case "$PLATFORM_NAME" in
    iphoneos) TARGET=arm64-apple-ios SHA256=638e2efa7e7eae76da88108961b281561d354b740b0ea091ffc093f3beaef0c6 ;;
    iphonesimulator) TARGET=arm64-apple-ios-simulator SHA256=3540593300b515c7a0bec9b2c8123d151f777b9451bc03e1c7a9512306998621 ;;
    *) echo "error: no libcurl-impersonate for $PLATFORM_NAME"; exit 1 ;;
esac
CACHE="$PROJECT_DIR/../build/cache"
ARCHIVE="$CACHE/libcurl-impersonate-$VERSION.$TARGET.tar.gz"
LIBRARY="$CACHE/libcurl-impersonate-$VERSION-$TARGET"

if [ ! -f "$LIBRARY/libcurl-impersonate.4.dylib" ]; then
    mkdir -p "$CACHE"
    if [ ! -f "$ARCHIVE" ]; then
        if ! curl -fsSL -o "$ARCHIVE.download" \
            "https://github.com/lexiforest/curl-impersonate/releases/download/$VERSION/libcurl-impersonate-$VERSION.$TARGET.tar.gz"; then
            echo "warning: couldn't download libcurl-impersonate; Google Lens and Bing won't work"
            exit 0
        fi
        mv "$ARCHIVE.download" "$ARCHIVE"
    fi
    if [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$SHA256" ]; then
        echo "error: $ARCHIVE isn't the release's (its SHA-256 differs): delete it to download it again"
        exit 1
    fi
    mkdir -p "$LIBRARY"
    tar -xzf "$ARCHIVE" -C "$LIBRARY" 'libcurl-impersonate.4*.dylib' 'LICENSE*'
fi

FRAMEWORK="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libcurl-impersonate.framework"
mkdir -p "$FRAMEWORK"
cp -L "$LIBRARY/libcurl-impersonate.4.dylib" "$FRAMEWORK/libcurl-impersonate"
cp "$LIBRARY"/LICENSE* "$FRAMEWORK/"
# (Its signature is made again below.)
install_name_tool -id @rpath/libcurl-impersonate.framework/libcurl-impersonate "$FRAMEWORK/libcurl-impersonate" 2>/dev/null
cat > "$FRAMEWORK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>libcurl-impersonate</string>
	<key>CFBundleIdentifier</key>
	<string>$PRODUCT_BUNDLE_IDENTIFIER.curl-impersonate</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>libcurl-impersonate</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION#v}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION#v}</string>
	<key>MinimumOSVersion</key>
	<string>$IPHONEOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$FRAMEWORK"
fi
