// Settings → Yomitan Popup when Yomitan's first displayOptions answer fails (a 503): its rows aren't controlled by
// Yomitan at first, and are once YomitanAPIStatus asks again (its next check, within 30 s); then as in
// yomitan-profile.test.js.
// mock: MOCK_PROFILE=1 MOCK_PROFILE_FAIL=1
// driver: python3 -I "$REPO/Tests/App/settings/yomitan-profile-driver.py" retry
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
