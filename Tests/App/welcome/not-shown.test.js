// Without MACPOPUP_SHOW_WELCOME, a launch with settings saved (any launch after the first) shows no welcome window and
// doesn't mark it shown.
// driver: python3 -I "$REPO/Tests/App/welcome/welcome-driver.py" not-shown

// The driver waits for this before looking for the window.
if (location.pathname.endsWith('/overlay.html')) wait(1000).then(() => log('overlay loaded'));
