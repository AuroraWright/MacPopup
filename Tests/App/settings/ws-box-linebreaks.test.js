// Settings → WebSockets' URL box with real keys (ws-box-driver.py linebreaks): A stored URL with line breaks in it
// (from a backup edited by hand) shows as lines, the list keeping 5: typing x on the fifth, Return (which beeps, adding
// nothing: typing there once recursed until the stack overflowed) and y saves …/a … …/d, …/exy, the box 5
// lines tall.
// Types into the test instance's Settings window and clicks into its URL box (only while it's in front; the pointer is
// put back afterwards).
// interactive
// settings: {"websocketUrls": ["ws://127.0.0.1:1/a\nws://127.0.0.1:1/b\nws://127.0.0.1:1/c", "ws://127.0.0.1:1/d", "ws://127.0.0.1:1/e", "ws://127.0.0.1:1/f"], "showConnectionErrors": false, "continuousReconnect": false}
// driver: python3 -I "$REPO/Tests/App/settings/ws-box-driver.py" linebreaks
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
