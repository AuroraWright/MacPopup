// Settings shared by the overlay, the popups and the settings window.
// Keys in the first two groups mirror texthooker-ui's settings; popup/scanning/anki keys mirror
// the Yomitan options of the same name (the Yomitan API doesn't expose them, so they live here).

export const themes = [
	'light', 'dark', 'cupcake', 'bumblebee', 'emerald', 'corporate', 'synthwave', 'retro', 'cyberpunk',
	'valentine', 'halloween', 'garden', 'forest', 'aqua', 'lofi', 'pastel', 'fantasy', 'wireframe', 'black',
	'luxury', 'dracula', 'cmyk', 'autumn', 'business', 'acid', 'lemonade', 'night', 'coffee', 'winter',
];

export const onlineFonts = ['Off', 'Noto Serif JP', 'Klee One', 'Shippori Mincho', 'Ackaisyo', 'CineCaption226'];

// Yomitan's default `sentenceParsing.terminationCharacters`.
function defaultTerminationCharacters() {
	const quotes = [['「', '」'], ['『', '』'], ['"', '"'], ["'", "'"]];
	const terminators = ['.', '!', '?', '．', '。', '！', '？', '…', '︒', '︕', '︖', '︙'];
	return [
		...quotes.map(([character1, character2]) => ({ enabled: true, character1, character2, includeCharacterAtStart: false, includeCharacterAtEnd: false })),
		...terminators.map((character1) => ({ enabled: true, character1, character2: null, includeCharacterAtStart: false, includeCharacterAtEnd: true })),
	];
}

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
	linePadding: 1,
	onlineFont: 'Off',
	maxLines: 0,
	preventLastDuplicate: 0,
	preventGlobalDuplicate: false,
	mergeEqualLineStarts: false,
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

	// Screen OCR mode: popups for the text of another app's window, read with Live Text (see lib/ocr-layer.js).
	ocrMode: false,
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
	// Percentage of the watched area that has to change before the window is read again.
	ocrChangeThreshold: 0.3,
	ocrPollInterval: 500,
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

	// Yomitan API
	yomitanApiUrl: 'http://127.0.0.1:19633',
	// The ISO code of the Yomitan profile's language (general.language; see lib/languages.js). Lookups
	// use Yomitan's own; this one is for what MacPopup does itself: audio, text display, scan resolution,
	// and the language OCR mode reads (Live Text's, and which lines are kept; see OCRLanguage.swift).
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
	// Each dictionary's collapse mode from Import Yomitan, [{name, mode}]; others use definitionsCollapsible.
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
	// With audio sources set, Yomitan's default ones for Japanese follow them (Yomitan's
	// audio.enableDefaultAudioSources).
	audioDefaultSources: true,
	// Percent.
	audioVolume: 100,
	// Played when no audio is found: 'none', 'click' or 'bloop'.
	audioFallbackSound: 'click',
	// Yomitan's audio sources from Import Yomitan, [{type, url, voice}], listed by right-clicking a play button.
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

	// Sentence audio (SentenceAudio.swift): a shortcut records the game's voice line for the newest cards.
	sentenceAudioEnabled: false,
	// {key, modifiers} as in hotkeys, or null.
	sentenceAudioShortcut: null,
	// The field for sentence audio, recorded (cards added today with the same sentence as the newest one get the
	// recording; their sentence field is the one their Yomitan card format fills with {sentence}) or from IINA.
	sentenceAudioField: 'SentenceAudio',
	// What's switched to before pressing keys: 'captured' (the captured window, ocrWindow, also outside
	// OCR mode), 'named' (the app sentenceAudioAppName) or 'none'.
	sentenceAudioApp: 'captured',
	sentenceAudioAppName: '',
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

	// IINA sentence audio (lib/anki-notes.js): cards made from the lines of iina-plugin/ get the line's audio, cut out
	// of the video file, in sentenceAudioField, with this much more before and after it (ms).
	iinaSentenceAudioEnabled: true,
	iinaSentenceAudioPadding: 500,
};
