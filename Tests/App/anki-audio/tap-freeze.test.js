// Keeping the game's audio (Anki Audio, sentenceAudioHistory) doesn't freeze MacPopup as the game's audio processes come
// and go: the game (windows/freezegame.swift) plays silence as its music and starts a quiet Tink (afplay, volume 0.05)
// as its child every 3 s, so the recorded audio's tap is made again as each sound starts and ends. tap-freeze-driver.py
// samples the app after each of 20 sounds: its main thread never stays waiting on a queue or in AudioDeviceStop (the
// 2026-11-14 deadlock), taps are made and none fails. Expected from evals/sentence-audio/verify-freeze.sh ("no
// freeze in 20 sounds") and the 2026-11-14 fix (memory: with a delay added to widen the race, the fixed code made 49
// taps without freezing). Gentle on purpose: a flood of sound processes once crashed coreaudiod; never make it faster.
// It plays sound: a quiet Tink every 3 s for about 75 s.
// interactive
// settings: {"ocrMode": false, "ocrWindow": {"ownerName": "freezegame", "title": "AudioTest"}, "ocrRegions": [], "websocketUrls": [], "clipboardMonitor": false, "ankiEnabled": true, "sentenceAudioEnabled": true, "sentenceAudioHistory": 1, "sentenceAudioShortcut": null, "sentenceAudioPlay": false, "screenshotHistory": 0}
// setup: "$REPO/Tests/App/anki-audio/voices.sh" "$RUN"
// beside: "$("$HARNESS/tools/build.sh" "$REPO/Tests/App/anki-audio/windows/freezegame.swift")" "$RUN/silence.wav" 150 3
// driver: python3 -I "$REPO/Tests/App/anki-audio/tap-freeze-driver.py" 20
// timeout: 150

// No page test: the driver checks.
