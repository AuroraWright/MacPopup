// The first-launch welcome window (forced with MACPOPUP_SHOW_WELCOME=1, as test runs save settings first): it marks
// itself shown, its Yomitan API row follows the API (Not detected, Detected once one answers, Not detected again when it
// stops), offering "Open Settings → Scanning" only while it isn't detected, which opens Settings on Scanning. Window-only
// shots of each state in the run folder.
// settings: {"yomitanApiUrl": "http://127.0.0.1:59884"}
// env: MACPOPUP_SHOW_WELCOME=1
// driver: python3 -I "$REPO/Tests/App/welcome/welcome-driver.py" shown
// timeout: 90
