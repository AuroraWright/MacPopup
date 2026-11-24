// Settings → Yomitan Popup when Yomitan's first displayOptions answer fails (a 503): its rows aren't controlled by
// Yomitan at first, and are once YomitanAPIStatus asks again (its next check, within 30 s); then as in
// yomitan-profile.test.js. (MOCK_PROFILE_FAIL_FOR=8: all of them in the first 8 s fail: the overlay's and the status
// check's at launch, in either order, and the status's check again right after the overlay's failed. Not a number of
// them: how many there are at launch varies.)
// mock: MOCK_PROFILE=1 MOCK_PROFILE_FAIL_FOR=8
// driver: python3 -I "$REPO/Tests/App/settings/yomitan-profile-driver.py" retry
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
