// Settings → WebSockets' URL box with real keys (ws-box-driver.py crlf): Text with Windows line breaks typed as one key
// press, as a paste puts it in, on a new line under ws://a: it's split into lines, keeping the ones that fit (ws://b …
// ws://e of ws://b … ws://g), the box 5 lines tall.
// Types into the test instance's Settings window and clicks into its URL box (only while it's in front; the pointer is
// put back afterwards).
// interactive
// settings: {"websocketUrls": ["ws://a"], "showConnectionErrors": false, "continuousReconnect": false}
// driver: python3 -I "$REPO/Tests/App/settings/ws-box-driver.py" crlf
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
