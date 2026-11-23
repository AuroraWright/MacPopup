// Settings → WebSockets' URL box with real keys (ws-box-driver.py long): A long URL doesn't wrap: with it second,
// Return and ws://x save three URLs, the box 4 lines tall (theirs and the empty one under them) and its text wider than
// the box.
// Types into the test instance's Settings window and clicks into its URL box (only while it's in front; the pointer is
// put back afterwards).
// interactive
// settings: {"websocketUrls": ["ws://127.0.0.1:59900", "ws://127.0.0.1:59901/a-very-long-path-that-goes-past-the-right-edge-of-the-settings-box/and-further-still/end"], "showConnectionErrors": false, "continuousReconnect": false}
// driver: python3 -I "$REPO/Tests/App/settings/ws-box-driver.py" long
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
