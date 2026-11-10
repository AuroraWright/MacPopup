#!/bin/zsh
# Builds a notarized build/notarized/MacPopup.app, and MacPopup-<version>.zip next to it to hand out. Usage:
# scripts/notarize.sh
# The notarytool keychain profile (made with `xcrun notarytool store-credentials`) is MACPOPUP_NOTARY_PROFILE, or else
# the first line of .notary-profile (kept out of git). The app is signed with MACPOPUP_NOTARY_IDENTITY, or else the
# keychain's first "Developer ID Application" certificate.
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${MACPOPUP_NOTARY_PROFILE:-}"
if [[ -z "$PROFILE" && -f .notary-profile ]]; then
    PROFILE="$(head -n 1 .notary-profile)"
fi
if [[ -z "$PROFILE" ]]; then
    echo "error: no notarytool keychain profile set (MACPOPUP_NOTARY_PROFILE or .notary-profile)" >&2
    exit 1
fi
IDENTITY="${MACPOPUP_NOTARY_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/^.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)"
fi
if [[ -z "$IDENTITY" ]] || ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "error: no Developer ID Application certificate (MACPOPUP_NOTARY_IDENTITY or the keychain)" >&2
    exit 1
fi

OUT="build/notarized"
APP="$OUT/MacPopup.app"
mkdir -p "$OUT"
MACPOPUP_APP="$APP" MACPOPUP_HARDENED=1 MACPOPUP_SIGN_IDENTITY="$IDENTITY" scripts/build.sh release

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ZIP="$OUT/MacPopup-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Sending $ZIP to Apple's notary service (it usually takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json >"$OUT/notarization.json"
STATUS="$(plutil -extract status raw "$OUT/notarization.json")"
if [[ "$STATUS" != Accepted ]]; then
    SUBMISSION="$(plutil -extract id raw "$OUT/notarization.json")"
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" "$OUT/notarization-log.json" >/dev/null || true
    echo "error: notarization $STATUS (submission $SUBMISSION); see $OUT/notarization-log.json" >&2
    exit 1
fi

# The ticket goes into the app, so it opens without asking Apple's servers; the zip is made again to hold it.
xcrun stapler staple -q "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute "$APP"
echo "Notarized $APP and $ZIP"
