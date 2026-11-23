// Settings → Floating Window → Font with a font, size and effects saved (Hiragino Mincho ProN W3, 30 px, red text on a
// green background, underline, shadow), over Accessibility by the driver (font-panel-driver.py seeded, after
// evals/settings-ax/steps-font-clear.zsh): the row's text names the font and size, drawn in the saved colors (a
// window-only screenshot of Settings in the run folder), with Clear enabled. Choose… shows that typeface and size 30 in
// the Fonts panel, and a size typed there (36) keeps the font and the effects as saved. Clear (the panel closed) saves
// the defaults ("", 24, {}) and keeps Line spacing (7); the row says "System font, 24 px" without the colors, and Clear
// is disabled. The user's "NSWindow Frame NSFontPanel" is put back as it was.
// settings: {"boxFontFamily": "HiraMinProN-W3", "fontSize": 30, "linePadding": 7, "boxFontEffects": {"color": "#ff0000ff", "backgroundColor": "#00c000ff", "underline": "single", "underlineColor": "#0000ffff", "shadow": {"x": 2, "y": 3, "blur": 4, "color": "#000000ff"}}}
// driver: python3 -I "$REPO/Tests/App/settings/font-panel-driver.py" seeded
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
