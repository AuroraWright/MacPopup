// The Settings window resizes in height only (the sections' layout is made for its 820 pt width; 677fb95): dragging its
// right edge out 200 pt and in 150 pt leaves its size as it was, and dragging its bottom edge down 150 pt (less when
// the screen has less room under it) makes it that much taller, as wide as before, and dragging it back up 150 pt past
// where it started leaves it as tall as it opened, its minimum (resize-driver.py).
// Drags the test instance's Settings window's edges with the real pointer (only where it's in front; the pointer is put
// back afterwards).
// interactive
// driver: python3 -I "$REPO/Tests/App/settings/resize-driver.py"
// timeout: 60

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
