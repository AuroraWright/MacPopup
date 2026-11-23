#!/bin/zsh
# wkaudio-app.sh <run folder>: makes WKAudioTest.app in the run folder (windows/wkaudio.swift as its executable,
# signed ad hoc) and opens it with the run folder's voice-app.wav (voices.sh), open for 60 s: an app of its own, whose
# web view plays the line once it gets SIGUSR1 (record-driver.py web sends it). For record-web.test.js's "// setup:".
set -euo pipefail
RUN=${1:A}
exe=$("${0:A:h:h}/harness/tools/build.sh" "${0:A:h}/windows/wkaudio.swift")
app="$RUN/WKAudioTest.app"
mkdir -p "$app/Contents/MacOS"
cp "$exe" "$app/Contents/MacOS/WKAudioTest"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WKAudioTest</string>
<key>CFBundleIdentifier</key><string>com.aury.macpopup.test.wkaudio</string>
<key>CFBundleName</key><string>WKAudioTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - --force "$app"
open -n --stdout "$RUN/wkaudio.log" --stderr "$RUN/wkaudio.log" "$app" --args "$RUN/voice-app.wav" 60
# Until its window is up (OCRController finds the captured window by its app's name and title).
for i in {1..50}; do
    pgrep -f "^$app/Contents/MacOS/WKAudioTest" >/dev/null && grep -q start "$RUN/wkaudio.log" 2>/dev/null && exit 0
    sleep 0.1
done
echo "WKAudioTest didn't start"; exit 1
