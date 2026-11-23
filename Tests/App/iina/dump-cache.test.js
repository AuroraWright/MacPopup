// The plugin dumps a line from IINA's cache (mpv dump-cache) when asked, as MacPopup asks for a live stream's line: the
// user's IINA (iina.py; history and recent files off for the run) plays the test video as a live HLS stream, and
// iina-dump.py asks the plugin for line 2 with 0.5 s around it: the reply names the file, which has video and audio
// with the line's tone; a file outside the temporary folder is refused. From scratch-tools/iina/streams/probe.sh. No
// page test: the driver checks.
// Opens the user's IINA (muted; not while it runs) and quits it; its settings and plugins are checked unchanged.
// interactive
// setup: python3 -I "$REPO/Tests/App/iina/iina.py" setup test
// beside: python3 -I "$REPO/Tests/App/iina/iina.py" beside
// driver: python3 -I "$REPO/Tests/App/iina/iina-dump.py"
// timeout: 120
