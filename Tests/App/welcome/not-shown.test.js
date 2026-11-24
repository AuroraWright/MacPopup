// Without MACPOPUP_SHOW_WELCOME, a launch with settings saved (any launch after the first) shows no welcome window and
// doesn't mark it shown (Settings, opened by the page, is listed: the windows are seen).
// driver: python3 -I "$REPO/Tests/App/welcome/welcome-driver.py" not-shown

// The driver waits for this before looking for the window, and then for Settings (opened 5 s later), which shows that
// Accessibility lists the instance's windows: no welcome window among them is then a check.
if (location.pathname.endsWith('/overlay.html')) {
	wait(1000).then(() => log('overlay loaded'));
	wait(6000).then(() => native('openSettings'));
}
