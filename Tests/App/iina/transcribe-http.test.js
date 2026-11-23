// "Transcribe videos without subtitles" (Live Caption) on the file over HTTP (serve.py on 59885). The user's IINA
// (iina.py; history and recent files off for the run) plays a video of six sentences said by Kyoko (made with say -o at
// setup, 3 s apart, no subtitles) muted, with its MacPopup plugin on 6680; iina-transcribe.py watches mpv and the
// transcript: it's loaded as the selected subtitle track "MacPopup transcription" soon after playback starts, has each
// sentence (most of its characters) starting near when it's said, no cue twice, and IINA shows the cues as they play.
// Live Caption's models are cloned from the user's (Application Support/MacPopup/SODA; setup fails without them). The
// transcripts are kept in /Users/Shared/Library/Caches/com.aury.macpopup/Transcripts (a path the plugin takes them
// from), not the user's. From scratch-tools/iina/subreload/run-e2e.sh and net-run.sh.
// Opens the user's IINA (muted; not while it runs) and quits it; its settings and plugins are checked unchanged.
// interactive
// setup: python3 -I "$REPO/Tests/App/iina/iina.py" setup speech
// beside: python3 -I "$REPO/Tests/App/iina/iina.py" beside
// settings: {"websocketUrls": ["ws://127.0.0.1:6680"], "continuousReconnect": true, "showConnectionErrors": false, "iinaTranscribe": true, "transcriptionModel": "soda", "transcriptionLive": false, "transcriptionSentenceEnds": false, "transcriptionPause": 1000, "language": "ja", "floatingWindowAudio": false, "ankiEnabled": false}
// env: MACPOPUP_TRANSCRIPTS_DIRECTORY=/Users/Shared/Library/Caches/com.aury.macpopup/Transcripts
// driver: python3 -I "$REPO/Tests/App/iina/iina-transcribe.py" http
// timeout: 150

// No page test: the driver checks, once the overlay has loaded.
if (location.pathname.endsWith('/overlay.html')) log('overlay loaded');
