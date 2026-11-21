// Settings shared by the overlay, the popups and the settings window.
// Keys in the first two groups mirror texthooker-ui's settings; popup/scanning/anki keys mirror
// the Yomitan options of the same name (the Yomitan API doesn't expose them, so they live here).

export const themes = [
	'light', 'dark', 'cupcake', 'bumblebee', 'emerald', 'corporate', 'synthwave', 'retro', 'cyberpunk',
	'valentine', 'halloween', 'garden', 'forest', 'aqua', 'lofi', 'pastel', 'fantasy', 'wireframe', 'black',
	'luxury', 'dracula', 'cmyk', 'autumn', 'business', 'acid', 'lemonade', 'night', 'coffee', 'winter',
];

// Yomitan's default `sentenceParsing.terminationCharacters`.
function defaultTerminationCharacters() {
	const quotes = [['「', '」'], ['『', '』'], ['"', '"'], ["'", "'"]];
	const terminators = ['.', '!', '?', '．', '。', '！', '？', '…', '︒', '︕', '︖', '︙'];
	return [
		...quotes.map(([character1, character2]) => ({ enabled: true, character1, character2, includeCharacterAtStart: false, includeCharacterAtEnd: false })),
		...terminators.map((character1) => ({ enabled: true, character1, character2: null, includeCharacterAtStart: false, includeCharacterAtEnd: true })),
	];
}

// The popup shortcut actions MacPopup supports: Yomitan's (all except switching profiles and toggling options), and its
// own addNoteSentenceAudio (see popup.js). Saved shortcuts with another action (e.g. "toggleOption", removed after 1.1)
// are left out.
export const popupHotkeyActions = new Set([
	'close', 'nextEntry', 'previousEntry', 'lastEntry', 'firstEntry', 'nextEntryDifferentDictionary',
	'previousEntryDifferentDictionary', 'historyBackward', 'historyForward', 'addNote', 'addNoteSentenceAudio', 'viewNotes',
	'playAudio', 'playAudioFromSource', 'copyHostSelection',
]);

// Yomitan's default keyboard shortcuts for popups (its `inputs.hotkeys` with the 'popup' scope).
function defaultHotkeys() {
	const hotkey = (action, argument, key, modifiers) => ({ action, argument, key, modifiers, enabled: true });
	return [
		hotkey('close', '', 'Escape', []),
		hotkey('previousEntry', '3', 'PageUp', ['alt']),
		hotkey('nextEntry', '3', 'PageDown', ['alt']),
		hotkey('lastEntry', '', 'End', ['alt']),
		hotkey('firstEntry', '', 'Home', ['alt']),
		hotkey('previousEntry', '1', 'ArrowUp', ['alt']),
		hotkey('nextEntry', '1', 'ArrowDown', ['alt']),
		hotkey('historyBackward', '', 'KeyB', ['alt']),
		hotkey('historyForward', '', 'KeyF', ['alt']),
		hotkey('addNote', '2', 'KeyK', ['alt']),
		hotkey('addNote', '0', 'KeyE', ['alt']),
		hotkey('addNote', '1', 'KeyR', ['alt']),
		hotkey('playAudio', '', 'KeyP', ['alt']),
		hotkey('viewNotes', '0', 'KeyV', ['alt']),
		hotkey('copyHostSelection', '', 'KeyC', ['ctrl']),
	];
}

export const defaultSettings = {
	// Connection
	websocketUrls: ['ws://localhost:6677'],
	continuousReconnect: true,
	showConnectionErrors: true,

	// Lines (texthooker-ui)
	theme: 'business',
	fontSize: 24,
	// Pixels above and below each line (beside it in vertical text).
	linePadding: 16,
	// The text box's font from the Fonts panel (Settings → Floating Window → Font): its PostScript name, or '' for
	// the system's.
	boxFontFamily: '',
	// The Fonts panel's effects, over the theme's: color, backgroundColor, underlineColor and strikethroughColor
	// ('#rrggbbaa'), underline and strikethrough ('single' or 'double'), shadow ({x, y, blur, color}, y down).
	boxFontEffects: {},
	maxLines: 0,
	preventLastDuplicate: 0,
	preventGlobalDuplicate: false,
	mergeEqualLineStarts: false,
	// Hides lines with none of the language's characters (see isInLanguage in lib/languages.js).
	filterNonCJKLines: false,
	preserveWhitespace: true,
	removeAllWhitespace: false,
	reverseLineOrder: false,
	displayVertical: false,
	showLinePoints: false,
	enableLineAnimation: false,
	// Copied text is added as a line, up to this many characters (Yomitan's background clipboard
	// monitor, which opens its search page instead).
	clipboardMonitor: false,
	floatingWindowOCR: false,
	// The speech of the captured window's app (or of every app) transcribed into lines, with transcriptionModel (see
	// AudioTranscriber.swift).
	floatingWindowAudio: false,
	clipboardMaxLength: 1000,
	replacements: [],
	customCSS: '',

	// Overlay window
	boxRect: null,
	boxOpacity: 0.85,
	showFurigana: false,
	// Furigana in hiragana, katakana, romaji, as the dictionary has it, or none (Yomitan's
	// parsing.readingMode): in the text box, and on cards ({sentence-furigana}; only hiragana and
	// katakana change those, as in Yomitan).
	furiganaReadingMode: 'hiragana',
	// Space between the words of tokenized lines (Yomitan's parsing.termSpacing).
	termSpacing: true,
	displayIndex: 0,
	windowLevel: 'screenSaver',

	// Transcription (Settings → Transcription): 'kitsune', 'animeWhisper', 'whisper', 'senseVoice' or 'parakeet'
	// (SpeechModel in Sources/Transcription), and how long a pause in the voice (ms) ends a line.
	transcriptionModel: 'kitsune',
	transcriptionPause: 1000,
	transcriptionSentenceEnds: false,
	transcriptionLive: false,

	// OCR: the text of another app's window, read with ocrEngine (see lib/ocr-layer.js).
	ocrMode: false,
	// Hide or show the overlays from any app, as the menu bar's Hide Overlays (AppDelegate.toggleOverlay), and switch
	// ocrMode (OCRController.switchOverlay): {key, modifiers} as in hotkeys, or null, and controller buttons, like
	// gamepadScanButtons (see overlay.js).
	overlayHideShortcut: null,
	overlayHideButtons: [],
	overlaySwitchShortcut: null,
	overlaySwitchButtons: [],
	// The window to read, {ownerName, title}, found again by these when MacPopup starts.
	ocrWindow: null,
	// Areas of the window to read, normalized to it ({x, y, width, height} in 0-1). Empty: the whole window.
	ocrRegions: [],
	ocrEngine: 'liveText',
	// Google Lens or Bing ('googleLens', 'bing') reads the dialogue once more for the reading that's shown (see
	// OCRController.finishReading).
	ocrCloudEngine: 'none',
	ocrResolution: 'auto',
	ocrStripFurigana: true,
	// How many WebSocket lines before the last are matched too, for games that add a line at a time to a page.
	ocrEarlierLines: 20,
	// Percentage of what is drawn in the watched area (not its plain background) that has to change before the window
	// is read again (see differs in OCRController.swift).
	ocrChangeThreshold: 0.3,
	ocrPollInterval: 500,
	// Only check for changes for a while after mouse, keyboard or controller input (OCRController.swift).
	ocrMouseWatch: true,
	ocrMouseWatchTime: 2000,
	// How long the recognized text has to stay the same before it's taken (text is often drawn gradually).
	ocrSettleTime: 400,
	ocrMaxWait: 8000,
	ocrUseWebsocket: true,
	// With WebSocket lines: the share of a line's letters a reading must match to show it (percent), and
	// how long the window is given to start showing a new line.
	ocrMatchThreshold: 60,
	ocrNewLineWait: 1500,
	ocrShowBoxes: false,

	// Scanning
	// 'none', 'shift', 'ctrl', 'alt', 'meta', or 'custom' to use the inputs below (see lib/scan-inputs.js).
	scanModifier: 'none',
	scanInputs: [],
	popupScanModifier: 'shift',
	popupScanInputs: [],
	scanLength: 16,
	scanDelay: 20,
	parser: 'scanning-parser',
	autoHideResults: false,
	hideDelay: 0,
	hidePopupOnCursorExit: false,
	hidePopupOnCursorExitDelay: 0,
	sentenceScanExtent: 200,
	sentenceTerminationCharacterMode: 'custom',
	sentenceTerminationCharacters: defaultTerminationCharacters(),
	// Highlights the text that was looked up (Yomitan's "Select matched text").
	selectMatchedText: true,
	// A scan key pressed while the pointer rests looks up the word under it (Yomitan's "Scan without
	// mouse move"); otherwise the pointer has to move.
	scanWithoutMousemove: true,
	// Yomitan's "Scan resolution": 'character' looks up from the character under the cursor, 'word' from
	// the start of the word it's in.
	scanResolution: 'character',
	// Headwords in popups can be scanned (Yomitan's scanning.enableOnPopupExpressions).
	popupScanExpressions: false,
	// Show dictionary tags of the "search" category (Yomitan's scanning.enableSearchTags).
	showSearchTags: false,
	// The mouse's back and forward buttons go through a popup's history unless this is on (Yomitan's
	// scanning.preventBackForward.onPopupPages).
	preventBackForwardInPopups: false,
	// How many popups can open from popups (Yomitan's "Maximum number of child popups").
	popupNestingMaxDepth: 10,
	// Clicking text in a popup's results looks it up in that popup (Yomitan's scanning.enablePopupSearch).
	popupSearchOnClick: false,
	// Keyboard shortcuts while a popup shows, [{action, argument, key, modifiers, enabled}] as in Yomitan's
	// inputs.hotkeys: `key` is a KeyboardEvent.code and `modifiers` lists 'alt', 'ctrl', 'shift' and 'meta'.
	hotkeys: defaultHotkeys(),
	// Game controller buttons (GameController's names, e.g. "Button A") that give the text controller focus (see
	// overlay.js); popup shortcuts can have `buttons` too.
	gamepadScanButtons: [],
	// How long (ms) the controller rests on a character or word before its popup opens.
	gamepadPopupDelay: 1000,
	// Where the controller starts in the OCR overlay's text without a WebSocket match: 'bottom' or 'top' (left or right in
	// vertical text).
	gamepadOcrStart: 'bottom',
	// What MacPopup learned of each controller model, by "vendor:product" (see GamepadLearning.swift).
	gamepadLayouts: {},

	// Yomitan API
	yomitanApiUrl: 'http://127.0.0.1:19633',
	// Freezes the game while a popup is open or the controller has focus (GamePause.swift).
	gamePause: false,
	// Pauses the game until pressed again, to hover over what's on screen (togglePausedScan in overlay.js).
	gamePauseShortcut: null,
	// The ISO code of the Yomitan profile's language (general.language; see lib/languages.js). Lookups
	// use Yomitan's own; this one is for what MacPopup does itself: audio, text display, scan resolution,
	// and the language OCR reads (Live Text's, and which lines are kept; see OCRLanguage.swift).
	language: 'ja',

	// Popup appearance (Yomitan general options)
	popupWidth: 400,
	popupHeight: 250,
	popupHorizontalOffset: 0,
	popupVerticalOffset: 10,
	popupHorizontalOffset2: 10,
	popupVerticalOffset2: 0,
	popupHorizontalTextPosition: 'below',
	popupVerticalTextPosition: 'before',
	popupScalingFactor: 1,
	// With a Yomitan whose API has displayOptions (see lib/yomitan-profile.js), popups take its profile's display
	// options instead of the settings below that it has.
	useYomitanDisplay: true,
	popupDisplayMode: 'default',
	// Where full-width popups go: 'top', 'bottom' or 'above-cursor'.
	popupFullWidthPosition: 'bottom',
	popupTheme: 'site',
	popupOuterTheme: 'site',
	fontFamily: '',
	popupFontSize: 14,
	lineHeight: '1.5',
	glossaryLayoutMode: 'default',
	compactTags: false,
	averageFrequency: false,
	frequencyDisplayMode: 'split-tags-grouped',
	termDisplayMode: 'ruby',
	showPitchAccentDownstepNotation: true,
	showPitchAccentPositionNotation: true,
	showPitchAccentGraph: false,
	popupCurrentIndicatorMode: 'triangle',
	popupActionBarVisibility: 'auto',
	popupActionBarLocation: 'top',
	definitionsCollapsible: 'not-collapsible',
	// Each dictionary's collapse mode from Import Yomitan, [{name, mode}]; others use definitionsCollapsible. (A Yomitan
	// whose API has dictionaryInfo gives its own, as it does the styles and yomitanAnkiTemplates' dictionaries and
	// resultOutputMode below, and the dictionaries' summaries as yomitanDictionaryInfo.)
	dictionaryCollapsible: [],
	customPopupCss: '',
	customPopupOuterCss: '',
	// Each dictionary's own CSS from Yomitan, [{name, styles}], applied to that dictionary's entries.
	dictionaryStyles: [],
	// Anki field templates from Import Yomitan:
	// {fieldTemplates: ?string (null for Yomitan's defaults), dictionaries, resultOutputMode}.
	yomitanAnkiTemplates: null,
	// Render Anki fields with yomitanAnkiTemplates instead of the Yomitan API, which can't see the popup selection.
	ankiRenderTemplatesLocally: false,
	// Play buttons are shown (Yomitan's audio.enabled).
	audioEnabled: true,
	audioAutoPlay: false,
	// With audio sources set, Yomitan's default ones for the language follow them (Yomitan's
	// audio.enableDefaultAudioSources).
	audioDefaultSources: true,
	// Percent.
	audioVolume: 100,
	// Played when no audio is found: 'none', 'click' or 'bloop'.
	audioFallbackSound: 'click',
	// Yomitan's audio sources from Import Yomitan, [{type, url, voice, apiKey}], listed by right-clicking a play button.
	audioSources: [],

	// Anki
	ankiEnabled: true,
	ankiConnectUrl: 'http://127.0.0.1:8765',
	ankiConnectKey: '',
	ankiTags: 'yomitan',
	checkForDuplicates: true,
	duplicateScope: 'collection',
	duplicateScopeCheckAllModels: false,
	duplicateBehavior: 'new',
	noteGuiMode: 'browse',
	screenshotFormat: 'jpeg',
	screenshotQuality: 92,
	screenshotResolution: '1x',
	// How many recent lines keep a screenshot of the captured window, taken this long (ms) after the line appears, for
	// cards made from them. 0 means the screenshot is taken when the card is made.
	screenshotHistory: 20,
	screenshotDelay: 1000,
	ankiSuspendNewCards: false,
	ankiForceSync: false,
	// Tags and flags of existing notes, shown next to their buttons: 'never', 'always', 'non-standard'
	// (tags other than ankiTags) or 'custom' (only ankiTargetTags).
	ankiDisplayTagsAndFlags: 'never',
	ankiTargetTags: '',
	// Shows the note buttons from a quick duplicate check on the term before the notes are rendered.
	ankiNoteDupeCheckFirst: false,
	// For audio downloaded by MacPopup for cards (the audio chosen in the play button menu), in ms; 0 = no limit.
	ankiDownloadTimeout: 0,

	// Sentence audio (SentenceAudio.swift): a shortcut records the game's voice line for the cards last added from a popup.
	sentenceAudioEnabled: false,
	// {key, modifiers} as in hotkeys, or null.
	sentenceAudioShortcut: null,
	// Controller buttons for the same, at any time, like gamepadScanButtons (see overlay.js).
	sentenceAudioButtons: [],
	// The field for sentence audio, recorded (the cards added from the same line as the last one get the recording)
	// or from IINA.
	sentenceAudioField: 'SentenceAudio',
	// What's switched to before pressing keys: 'captured' (the captured window, ocrWindow, whatever the
	// overlay type), 'named' (the app sentenceAudioAppName) or 'none'.
	sentenceAudioApp: 'captured',
	sentenceAudioAppName: '',
	// Minutes of the game's audio to keep, so a line's voice can be taken without replaying it (0 keeps none).
	sentenceAudioHistory: 5,
	// Whether overwriting a card from a popup replaces its sentence audio, with IINA's clip of the line or with Anki
	// Audio's recording after an Option-click. When off, only an empty sentenceAudioField is filled.
	sentenceAudioOverwrite: true,
	// Visual novel backlog capture: a line missing from the kept audio is replayed from the game's backlog (using the
	// keys below) and recorded.
	sentenceAudioBacklog: true,
	// Keys pressed to open the game's backlog (replaying the line) and to close it, [{key, modifiers}].
	sentenceAudioOpenKeys: [],
	sentenceAudioCloseKeys: [],
	// In ms: before pressing keys (after switching apps), between keys, and how long each is held.
	sentenceAudioKeyDelay: 1000,
	sentenceAudioKeyInterval: 800,
	sentenceAudioKeyHold: 100,
	// In ms, after the keys, before recording (without voice detection, which waits for the voice).
	sentenceAudioRecordDelay: 500,
	// Automatically detect start and end of speech; otherwise the shortcut starts and stops the recording.
	sentenceAudioDetectVoice: true,
	// In seconds: how long to wait for the voice to start.
	sentenceAudioVoiceWait: 10,
	// In ms: the voice has ended after this long without it (or after the padding, if longer).
	sentenceAudioPause: 3000,
	// In ms: kept before and after the detected voice.
	sentenceAudioPadding: 500,
	// In seconds.
	sentenceAudioMaxLength: 60,
	sentenceAudioPlay: true,

	// IINA (lib/anki-notes.js): cards made from iina-plugin/ lines get the frame from the middle of the line as their
	// {screenshot}, and the line's audio, cut from the video, in sentenceAudioField, padded by this much (ms) on each
	// side.
	iinaScreenshotEnabled: true,
	iinaSentenceAudioEnabled: true,
	iinaSentenceAudioPadding: 500,
};
