// Settings → WebSockets' URL box with real keys (ws-box-driver.py fifth): Return and a letter four times under ws://a,
// then Return on the fifth line (which beeps, adding nothing) and f: f goes on the fifth line (ws://a, b, c, d, ef),
// the box 5 lines tall.
// Types into the test instance's Settings window and clicks into its URL box (only while it's in front; the pointer is
// put back afterwards).
// interactive
// settings: {"websocketUrls": ["ws://a"], "showConnectionErrors": false, "continuousReconnect": false}
// driver: python3 -I "$REPO/Tests/App/settings/ws-box-driver.py" fifth
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
