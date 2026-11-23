// Each of Settings' sections renders (sections-driver.py sections, after evals/settings-shot/run.sh): the
// sidebar lists the 15 sections the driver knows, and shown in turn, each shows a text of its own, its window-only
// screenshot (in the run folder) is the window's size and not blank, and a second one a second later shows the same
// form (the title bar and sidebar change with the window's being active).
// driver: python3 -I "$REPO/Tests/App/settings/sections-driver.py" sections
// timeout: 180

// Opens Settings (the driver picks the sections): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
