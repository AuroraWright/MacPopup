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

export const defaultSettings = {
	// Connection
	websocketUrls: ['ws://localhost:6677'],
	continuousReconnect: true,
	showConnectionErrors: true,
	showConnectionIcon: true,

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
	replacements: [],
	customCSS: '',

	// Overlay window
	boxRect: null,
	boxOpacity: 0.85,
	showFurigana: false,
	showTokenUnderline: true,
	displayIndex: 0,
	windowLevel: 'screenSaver',

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

	// Yomitan API
	yomitanApiUrl: 'http://127.0.0.1:19633',

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
	customPopupCss: '',
	customPopupOuterCss: '',
	// Each dictionary's own CSS from Yomitan, [{name, styles}], applied to that dictionary's entries.
	dictionaryStyles: [],
	// Anki field templates from Import Yomitan:
	// {fieldTemplates: ?string (null for Yomitan's defaults), dictionaries, resultOutputMode, readingMode}.
	yomitanAnkiTemplates: null,
	// Render Anki fields with yomitanAnkiTemplates instead of the Yomitan API, which can't see the popup selection.
	ankiRenderTemplatesLocally: false,
	audioAutoPlay: false,

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
};
