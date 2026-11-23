// The app's memory and CPU while idle (profile-driver.py idle): the Floating Window open with nothing to read, no OCR,
// WebSocket, clipboard or audio, left alone 15 s and then sampled every second for 45 s. MacPopup's footprint at most
// 45 MB, its WebContent's 100 MB, all its processes' 180 MB, growing at most 4 MB over the 45 s; CPU in the median second
// at most 1.9% of a core for MacPopup and 3.1% for all its processes, and on average 2.7% and 3.7% (about 1.5x the most
// measured; see the driver). Someone moving the pointer meanwhile adds CPU (the app follows it).
// driver: python3 -I "$REPO/Tests/App/profile/profile-driver.py" idle
// timeout: 120
