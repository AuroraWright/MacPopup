// The Fonts panel while Settings changes, over Accessibility by the driver (font-panel-driver.py scroll, after
// evals/settings-ax/steps-font-scroll.zsh): opened with Choose…, it stays open while the Font row is scrolled out of view
// (the form may unload the row; the panel is closed with the section or the window, not with the row) and back; showing
// another section (General) closes it, with Settings left open; opened again on Floating Window, closing Settings closes
// it. The user's "NSWindow Frame NSFontPanel" is put back as it was.
// driver: python3 -I "$REPO/Tests/App/settings/font-panel-driver.py" scroll
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
