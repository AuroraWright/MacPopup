// Settings → Yomitan Popup with a Yomitan that gives its profile (displayOptions, dictionaryInfo): the rows it gives
// are greyed out with "Controlled by your Yomitan settings."; with "Use Yomitan's display settings" turned off (over
// Accessibility), only the dictionary rows (collapse behavior, collapse rules, dictionary styles) stay so.
// mock: MOCK_PROFILE=1
// driver: python3 -I "$REPO/Tests/App/settings/yomitan-profile-driver.py"

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
