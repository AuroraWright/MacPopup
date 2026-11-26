// The pause helper only takes requests from MacPopup (its identifier, signed by the same team): another program
// (pause-client.swift, signed ad hoc) asking it to stop a process is refused, and the process keeps running. Needs the
// pause helper loaded (Settings → Permissions → Pause helper); without it, the first check fails.
// settings: {"gamePause": false}
// driver: python3 -I "$REPO/Tests/App/game-pause/foreign-client-driver.py"
// Starts no window: no page test, the driver checks.
