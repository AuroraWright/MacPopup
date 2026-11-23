// Settings → Scanning's advanced scanning inputs, edited over Accessibility by the driver: an edit still going on when a
// row above it is removed is saved to its own row (not to the popup's list, nor to the row that took its place), an
// unknown input name isn't saved and is pointed out, names are saved in Yomitan's order, and Remove removes its row.
// settings: {"scanModifier": "custom", "scanInputs": ["shift", "alt", "ctrl"], "popupScanModifier": "custom", "popupScanInputs": ["mouse2"]}
// driver: python3 -I "$REPO/Tests/App/settings/scan-inputs-driver.py"

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
