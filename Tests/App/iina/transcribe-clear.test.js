// Settings → IINA Integration → Saved transcriptions → Clear… then Clear, pressed while IINA's video is being
// transcribed ("Transcribe videos without subtitles", Live Caption). The user's IINA (iina.py; history and recent files
// off for the run) plays, muted, Kyoko's six sentences (made with say -o at setup) looped into about 20 minutes, so that
// the transcription ahead is still running when Clear is pressed, 20 s into playback; iina-transcribe-clear.py presses
// the buttons over Accessibility and watches mpv and the transcripts folder (every 20 ms) meanwhile.
// Expected (VideoTranscriber.clearTranscripts: the job being made is discarded, so its worker stops and it never
// saves again; the folder is removed; update() then starts a new job for the same video, from where it's played):
// - the transcripts folder (/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts, MACPOPUP_TRANSCRIPTS_DIRECTORY,
//   a path the plugin takes transcripts from) is removed, then made again by the new transcript;
// - the transcription starts over from about 2 s before the position played (one more "transcribing IINA's video
//   ahead"): no line from before that is written back, neither by the old job nor in the new transcript;
// - IINA keeps one "MacPopup transcription" track, selected, of the same file, read again (sub-reload) once the new
//   transcript is saved, and shows the sentences said after the clear as they play;
// - Settings' row then counts the new transcript (1 video), no "Couldn't clear" alert, the app still runs.
// The user's transcripts (~/Library/Caches) and IINA's settings and plugins are checked unchanged. From
// evals/iina/clear/during.sh (anime-whisper on an anime clip, cleared about 40 s in).
// Opens the user's IINA (muted; not while it runs) and quits it.
// interactive
// setup: python3 -I "$REPO/Tests/App/iina/iina-transcribe-clear.py" setup
// beside: python3 -I "$REPO/Tests/App/iina/iina.py" beside
// settings: {"websocketUrls": ["ws://127.0.0.1:6680"], "continuousReconnect": true, "showConnectionErrors": false, "iinaTranscribe": true, "transcriptionModel": "soda", "transcriptionLive": false, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "language": "ja", "floatingWindowAudio": false, "ankiEnabled": false}
// env: MACPOPUP_TRANSCRIPTS_DIRECTORY=/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts
// driver: python3 -I "$REPO/Tests/App/iina/iina-transcribe-clear.py"
// timeout: 180

// Opens Settings (the driver picks the section): no page test, the driver checks.
if (location.pathname.endsWith('/overlay.html')) {
	log('overlay loaded');
	wait(2000).then(() => native('openSettings'));
}
