// Settings → Floating Window → Font and the macOS Fonts panel, over Accessibility by the driver (font-panel-driver.py
// panel, after evals/settings-ax/steps-font*.zsh): the row says "System font, 24 px" with Clear disabled; Choose… shows
// the Fonts panel at the Settings window's level (above the floating level the panel takes by itself), as the key
// window, showing size 24. A size typed into the panel saves fontSize (30) and the row says so, with Clear enabled; the
// panel's shadow switch and underline (Double) and strikethrough (Single) menus save boxFontEffects. Clear with the
// panel open saves the defaults again ("", 24, {}), and the panel shows them (size 24, shadow off); closing Settings
// closes the panel. The user's "NSWindow Frame NSFontPanel" (which the instance's panel saves in com.aury.macpopup) is
// put back as it was. Not covered: picking a typeface or style in the panel's lists (their actions only come from real
// clicks), and its color wells (they open the color panel, which saves its own state in com.aury.macpopup).
// driver: python3 -I "$REPO/Tests/App/settings/font-panel-driver.py" panel
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
