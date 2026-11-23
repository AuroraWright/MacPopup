// Settings → IINA Integration → Saved transcriptions, over Accessibility by the driver (iina-clear-driver.py), with the
// instance's transcripts folder (MACPOPUP_TRANSCRIPTS_DIRECTORY, in the run folder) holding two made-up videos' files
// (setup): the row says "2 videos" and their size; Clear… asks first, and Cancel keeps them; Clear… then Clear removes
// the folder, and the row says "None" with Clear… disabled. The user's own transcripts (~/Library/Caches) are listed
// before and after: unchanged. From evals/iina/clear run.sh and steps-clear.zsh (no IINA needed).
// setup: T="$RUN/Library/Caches/com.aury.macpopup/Transcripts"; mkdir -p "$T/aaaa" "$T/bbbb" && head -c 300000 /dev/zero > "$T/aaaa/lines.json" && printf '1\n00:00:01,000 --> 00:00:02,000\nテスト\n' > "$T/aaaa/MacPopup transcription" && head -c 50000 /dev/zero > "$T/bbbb/lines.json"
// driver: python3 -I "$REPO/Tests/App/settings/iina-clear-driver.py"
// timeout: 90

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) wait(2000).then(() => native('openSettings'));
