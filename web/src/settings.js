import { ankiInvoke } from './lib/anki-connect.js';
import { log, nativeCall } from './lib/native.js';
import { onlineFonts, themes } from './lib/settings-defaults.js';
import { getSettings, loadSettings, onSettingsChanged, resetSettings, saveSettings } from './lib/settings.js';
import { yomitanVersion } from './lib/yomitan-api.js';
import { formatScanInput, isValidInputName, keyNameFromCode, mouseButtonNames, parseScanInput } from './lib/scan-inputs.js';
import { convertYomitanProfile, parseYomitanExport } from './lib/yomitan-import.js';
import defaultFieldTemplates from '../../vendor/yomitan/ext/data/templates/default-anki-field-templates.handlebars';

const option = (value, label = value) => ({ value, label });
const scanModifierOptions = [
	option('none', 'None (hover)'),
	option('shift', 'Shift'),
	option('ctrl', 'Control'),
	option('alt', 'Option'),
	option('meta', 'Command'),
	option('custom', 'Custom…'),
];
const options = (...values) => values.map((value) => option(value));

// Field types: text, number, checkbox, select, textarea, lines (string[] one per line), json,
// scanInputs (custom scan input list, see lib/scan-inputs.js).
const sections = [
	{
		title: 'Connection',
		fields: [
			{ key: 'websocketUrls', label: 'Websockets (one per line)', type: 'lines' },
			{ key: 'continuousReconnect', label: 'Continuous Reconnect', type: 'checkbox' },
			{ key: 'showConnectionErrors', label: 'Show Connection Errors', type: 'checkbox' },
			{ key: 'showConnectionIcon', label: 'Show Connection Icon', type: 'checkbox' },
		],
	},
	{
		title: 'Lines',
		fields: [
			{ key: 'theme', label: 'Theme', type: 'select', options: options(...themes) },
			{ key: 'fontSize', label: 'Font Size', type: 'number', min: 1 },
			{ key: 'linePadding', label: 'Line Padding', type: 'number', min: 0, step: 0.1 },
			{ key: 'onlineFont', label: 'Online Font', type: 'select', options: options(...onlineFonts) },
			{ key: 'preventLastDuplicate', label: 'Prevent Last Line Duplicate', type: 'number', min: 0 },
			{ key: 'maxLines', label: 'Max lines (0 = unlimited)', type: 'number', min: 0 },
			{ key: 'preventGlobalDuplicate', label: 'Prevent global Duplicates', type: 'checkbox' },
			{ key: 'mergeEqualLineStarts', label: 'Merge equal Line Starts', type: 'checkbox' },
			{ key: 'filterNonCJKLines', label: 'Filter non-CJK Lines', type: 'checkbox' },
			{ key: 'preserveWhitespace', label: 'Preserve Whitespace', type: 'checkbox' },
			{ key: 'removeAllWhitespace', label: 'Remove all Whitespace', type: 'checkbox' },
			{ key: 'reverseLineOrder', label: 'Reverse Line Order', type: 'checkbox' },
			{ key: 'displayVertical', label: 'Display Text vertically', type: 'checkbox' },
			{ key: 'showLinePoints', label: 'Show Line Points', type: 'checkbox' },
			{ key: 'enableLineAnimation', label: 'Enable Line Animation', type: 'checkbox' },
			{ key: 'showFurigana', label: 'Show Furigana (from the Yomitan tokenizer)', type: 'checkbox' },
			{ key: 'showTokenUnderline', label: 'Underline hovered Word', type: 'checkbox' },
			{
				key: 'replacements',
				label: 'Replacements (JSON: [{"pattern", "replaces", "flags": ["g"], "enabled"}])',
				type: 'json',
			},
			{ key: 'customCSS', label: 'Custom CSS (text box)', type: 'textarea' },
		],
	},
	{
		title: 'Window',
		fields: [
			{ key: 'boxOpacity', label: 'Background Opacity (0-1)', type: 'number', min: 0, max: 1, step: 0.05 },
			{ key: 'displayIndex', label: 'Display (0 = main)', type: 'number', min: 0 },
			{
				key: 'windowLevel',
				label: 'Window Level',
				type: 'select',
				options: [
					option('floating', 'Floating'),
					option('statusBar', 'Status bar'),
					option('popUpMenu', 'Pop-up menu'),
					option('screenSaver', 'Screen saver'),
					option('shielding', 'Shielding (above captured displays)'),
				],
			},
		],
	},
	{
		title: 'Screen OCR',
		description:
			'Instead of the text box, read another app’s window with Live Text and show popups when hovering its text. ' +
			'Toggle it with Screen OCR Mode in the menu bar. Needs the Screen Recording permission.',
		fields: [
			{ key: 'ocrMode', label: 'Screen OCR mode', type: 'checkbox' },
			{ key: 'ocrWindow', label: 'Window', type: 'ocrWindow' },
			{
				key: 'ocrLanguage',
				label: 'Language',
				type: 'select',
				options: [option('ja', 'Japanese'), option('zh-Hans', 'Chinese (Simplified)'), option('zh-Hant', 'Chinese (Traditional)'), option('ko', 'Korean'), option('en', 'English')],
			},
			{
				key: 'ocrResolution',
				label: 'Read at',
				type: 'select',
				options: [option('auto', 'Automatic'), option('full', 'Full resolution'), option('1x', '1x')],
				hint: 'Automatic reads windows drawn at 1x (e.g. a VM or a game that isn’t Retina aware, enlarged by macOS) at 1x, which is faster and loses nothing, and others at full Retina resolution. Choose one if text is misread: full resolution for small text, 1x if automatic picks full resolution for a window drawn at 1x.',
			},
			{
				key: 'ocrUseWebsocket',
				label: 'Use WebSocket lines',
				type: 'checkbox',
				hint: 'New lines from the WebSocket trigger reading the window, and recognized text that matches the line is replaced by it.',
			},
			{
				key: 'ocrChangeThreshold',
				label: 'Change threshold (%)',
				type: 'number',
				min: 0,
				step: 0.1,
				hint: 'The window is read again when this share of it (or of the chosen areas) changes (while a WebSocket is connected, only briefly after each line).',
			},
			{
				key: 'ocrPollInterval',
				label: 'Check for changes every (ms)',
				type: 'number',
				min: 50,
				hint: 'How often the window is compared with the last reading to notice new text: all the time, or with “Watch after mouse use” only for a while after the mouse is used. Shorter notices changes sooner but uses more CPU. While a WebSocket is connected, its lines are the cue instead, and the window is only watched briefly after each one.',
			},
			{
				key: 'ocrMouseWatch',
				label: 'Watch after mouse use',
				type: 'checkbox',
				hint: 'Without a WebSocket: only check for changes for a while after the mouse moves or clicks (e.g. to advance the text), instead of all the time, to save work while you read. Text that starts appearing in that time is read once it’s finished, however long that takes.',
			},
			{
				key: 'ocrMouseWatchTime',
				label: 'Watch for (ms)',
				type: 'number',
				min: 0,
				showIf: (settings) => settings.ocrMouseWatch,
				hint: 'How long changes are checked for after the mouse moves or clicks. Raise it if a game shows its next line only after a longer transition (otherwise it’s only read once you move the mouse again); keep it well above “Check for changes every”, so it’s checked several times.',
			},
			{
				key: 'ocrSettleTime',
				label: 'Wait until unchanged for (ms)',
				type: 'number',
				min: 0,
				hint: 'Text is read once the picture stops changing, so lines that are still being drawn aren’t read half-finished.',
			},
			{
				key: 'ocrStillTolerance',
				label: 'Ignore changes fainter than (0–255)',
				type: 'number',
				min: 0,
				max: 255,
				hint: 'How much a pixel’s brightness has to change to count as still changing while waiting. Higher reads sooner when text fades in slowly or the picture is grainy (e.g. a video background), but may read text before its last characters are fully drawn. Lower waits for every faint change.',
			},
			{
				key: 'ocrMaxWait',
				label: 'Read anyway after (ms)',
				type: 'number',
				min: 100,
				hint: 'If the picture keeps changing (e.g. slow text, or an animated background or effect), the window is read after this long anyway, and again once it stops changing. Choosing areas around the text avoids most of these waits.',
			},
			{
				key: 'ocrShowBoxes',
				label: 'Outline recognized text',
				type: 'checkbox',
				hint: 'For debugging: shows the recognized text and outlines its lines over the window, red for plain OCR text and green for lines corrected with the WebSocket line.',
			},
		],
	},
	{
		title: 'Scanning',
		fields: [
			{ key: 'yomitanApiUrl', label: 'Yomitan API URL', type: 'text', test: testYomitan },
			{
				key: 'scanModifier',
				label: 'Text box scan modifier',
				type: 'select',
				options: scanModifierOptions,
			},
			{ key: 'scanInputs', label: 'Text box scan inputs', type: 'scanInputs', showIf: (settings) => settings.scanModifier === 'custom' },
			{
				key: 'popupScanModifier',
				label: 'Popup scan modifier (nested lookups)',
				type: 'select',
				options: scanModifierOptions,
			},
			{ key: 'popupScanInputs', label: 'Popup scan inputs', type: 'scanInputs', showIf: (settings) => settings.popupScanModifier === 'custom' },
			{ key: 'scanLength', label: 'Scan Length', type: 'number', min: 1 },
			{ key: 'scanDelay', label: 'Scan Delay (ms)', type: 'number', min: 0 },
			{ key: 'parser', label: 'Tokenizer', type: 'select', options: [option('scanning-parser', 'Yomitan scanning parser'), option('mecab', 'MeCab')] },
			{ key: 'autoHideResults', label: 'Hide popup when scanning nothing (auto-hide results)', type: 'checkbox' },
			{ key: 'hideDelay', label: 'Auto-hide delay (ms)', type: 'number', min: 0 },
			{ key: 'hidePopupOnCursorExit', label: 'Hide popup when the cursor leaves it', type: 'checkbox' },
			{ key: 'hidePopupOnCursorExitDelay', label: 'Hide popup on cursor exit delay (ms)', type: 'number', min: 0 },
			{ key: 'sentenceScanExtent', label: 'Sentence scan extent', type: 'number', min: 1 },
			{
				key: 'sentenceTerminationCharacterMode',
				label: 'Sentence termination',
				type: 'select',
				options: [option('custom', 'Custom characters and newlines'), option('custom-no-newlines', 'Custom characters'), option('newlines', 'Newlines'), option('none', 'None')],
			},
			{
				key: 'sentenceTerminationCharacters',
				label: 'Sentence termination characters (JSON, Yomitan format)',
				type: 'json',
			},
		],
	},
	{
		title: 'Popup',
		description: 'Mirrors Yomitan’s Appearance and Popup settings (the Yomitan API doesn’t expose them).',
		fields: [
			{ key: 'popupTheme', label: 'Theme', type: 'select', options: [option('site', 'Site (follows text box)'), option('light', 'Light'), option('dark', 'Dark'), option('browser', 'System')] },
			{ key: 'popupOuterTheme', label: 'Shadow', type: 'select', options: [option('site', 'Site'), option('light', 'Light'), option('dark', 'Dark'), option('browser', 'System'), option('none', 'None')] },
			{ key: 'popupWidth', label: 'Width', type: 'number', min: 1 },
			{ key: 'popupHeight', label: 'Height', type: 'number', min: 1 },
			{ key: 'popupScalingFactor', label: 'Scaling factor', type: 'number', min: 0.1, step: 0.05 },
			{ key: 'popupHorizontalOffset', label: 'Horizontal offset', type: 'number' },
			{ key: 'popupVerticalOffset', label: 'Vertical offset', type: 'number' },
			{ key: 'popupHorizontalTextPosition', label: 'Position for horizontal text', type: 'select', options: options('below', 'above') },
			{ key: 'popupVerticalTextPosition', label: 'Position for vertical text', type: 'select', options: options('before', 'after', 'left', 'right', 'default') },
			{ key: 'popupDisplayMode', label: 'Display mode', type: 'select', options: [option('default', 'Default'), option('full-width', 'Full width')] },
			{ key: 'fontFamily', label: 'Font family', type: 'text' },
			{ key: 'popupFontSize', label: 'Font size', type: 'number', min: 1 },
			{ key: 'lineHeight', label: 'Line height', type: 'text' },
			{ key: 'glossaryLayoutMode', label: 'Glossary layout', type: 'select', options: [option('default', 'Default'), option('compact', 'Compact'), option('compact-popup-anki', 'Compact popup, default Anki')] },
			{ key: 'compactTags', label: 'Compact tags', type: 'checkbox' },
			{ key: 'averageFrequency', label: 'Show average frequency', type: 'checkbox' },
			{ key: 'frequencyDisplayMode', label: 'Frequency display', type: 'select', options: options('tags', 'tags-grouped', 'split-tags', 'split-tags-grouped', 'inline-list', 'list', 'list-bordered') },
			{ key: 'termDisplayMode', label: 'Term display', type: 'select', options: options('ruby', 'ruby-and-reading', 'term-and-reading', 'term-only') },
			{ key: 'showPitchAccentDownstepNotation', label: 'Pitch accent downstep notation', type: 'checkbox' },
			{ key: 'showPitchAccentPositionNotation', label: 'Pitch accent position notation', type: 'checkbox' },
			{ key: 'showPitchAccentGraph', label: 'Pitch accent graph', type: 'checkbox' },
			{ key: 'popupCurrentIndicatorMode', label: 'Current entry indicator', type: 'select', options: options('none', 'asterisk', 'triangle', 'bar-left', 'bar-right', 'dot-left', 'dot-right') },
			{ key: 'popupActionBarVisibility', label: 'Action bar visibility', type: 'select', options: options('auto', 'always') },
			{ key: 'popupActionBarLocation', label: 'Action bar location', type: 'select', options: options('top', 'bottom', 'left', 'right') },
			{ key: 'definitionsCollapsible', label: 'Collapsible definitions', type: 'select', options: options('not-collapsible', 'expanded', 'collapsed', 'force-expanded', 'force-collapsed') },
			{ key: 'audioAutoPlay', label: 'Auto-play audio', type: 'checkbox' },
			{ key: 'customPopupCss', label: 'Custom popup CSS (Yomitan “Popup CSS”)', type: 'textarea' },
			{ key: 'customPopupOuterCss', label: 'Custom popup outer CSS (Yomitan “Popup outer CSS”)', type: 'textarea' },
			{
				key: 'dictionaryStyles',
				label: 'Dictionary styles (from Import Yomitan)',
				type: 'imported',
				describe: (values) => values.map(({ name }) => name).join(', '),
				emptyText: 'None. Use Import Yomitan to copy them.',
				clearedValue: [],
			},
		],
	},
	{
		title: 'Anki',
		description: 'Card formats and handlebars come from the active Yomitan profile through the Yomitan API.',
		fields: [
			{ key: 'ankiEnabled', label: 'Enable Anki integration', type: 'checkbox' },
			{ key: 'ankiConnectUrl', label: 'AnkiConnect URL', type: 'text', test: testAnki },
			{ key: 'ankiConnectKey', label: 'AnkiConnect API key', type: 'text' },
			{ key: 'ankiTags', label: 'Card tags (space separated)', type: 'text' },
			{
				key: 'ankiRenderTemplatesLocally',
				label: 'Render the field templates below instead of using the Yomitan API',
				hint: 'Enable this to let templates use text selected in the popup (getMedia "popupSelectionText"), e.g. to pick a dictionary by selecting its name. The API can’t see the selection.',
				type: 'checkbox',
			},
			{
				key: 'yomitanAnkiTemplates',
				label: 'Field templates (Yomitan “Configure Anki card templates”)',
				hint: 'Copied by Import Yomitan. Only used with the option above; otherwise the API uses the templates in Yomitan.',
				type: 'ankiTemplates',
			},
			{ key: 'checkForDuplicates', label: 'Check for duplicates', type: 'checkbox' },
			{ key: 'duplicateScope', label: 'Duplicate scope', type: 'select', options: [option('collection', 'Collection'), option('deck', 'Deck'), option('deck-root', 'Deck root')] },
			{ key: 'duplicateScopeCheckAllModels', label: 'Check all models for duplicates', type: 'checkbox' },
			{ key: 'duplicateBehavior', label: 'When a duplicate is detected', type: 'select', options: [option('new', 'Allow adding'), option('prevent', 'Prevent adding'), option('overwrite', 'Overwrite existing note')] },
			{ key: 'noteGuiMode', label: 'Note viewer', type: 'select', options: [option('browse', 'Card browser'), option('edit', 'Note editor')] },
			{ key: 'screenshotFormat', label: 'Screenshot format', type: 'select', options: [option('jpeg', 'JPEG'), option('png', 'PNG')] },
			{ key: 'screenshotQuality', label: 'Screenshot quality (JPEG)', type: 'number', min: 0, max: 100 },
		],
	},
];

const inputs = new Map();
const conditionalFields = [];

// Custom scan inputs

const scanInputsHint =
	'Scanning happens while every key or button of one entry is held. An empty entry scans on hover. ' +
	'Like in Yomitan, entries combine the modifier keys meta (Command), ctrl, alt (Option) and shift with the mouse buttons ' +
	'mouse0 (left), mouse1 (right), mouse2 (middle), mouse3 (back), mouse4 (forward) and mouse5.';

let activeRecording = null;
window.__macpopupMouseButton = (number, isDown) => activeRecording?.onNativeButton(number, isDown);

/** Records the keys and mouse buttons pressed until the first release. Resolves to null if cancelled (Escape). */
function recordScanInput(button) {
	activeRecording?.cancel();
	return new Promise((resolve) => {
		const recorded = new Set();
		const originalText = button.textContent;
		let done = false;
		button.textContent = 'Press modifiers or buttons…';
		button.classList.add('btn-primary');

		const block = (event) => {
			event.preventDefault();
			event.stopPropagation();
		};
		const finish = (value) => {
			if (done) return;
			done = true;
			activeRecording = null;
			button.textContent = originalText;
			button.classList.remove('btn-primary');
			// Keep blocking until the click that follows the last mouseup has been dispatched.
			setTimeout(() => {
				for (const [type, listener] of listeners) window.removeEventListener(type, listener, true);
			}, 0);
			resolve(value);
		};
		const press = (event, names) => {
			block(event);
			if (done) return;
			for (const name of names) if (name) recorded.add(name);
			if (recorded.size > 0) button.textContent = formatScanInput([...recorded]);
		};
		const release = (event) => {
			block(event);
			if (!done && recorded.size > 0) finish(formatScanInput([...recorded]));
		};
		const listeners = [
			[
				'keydown',
				(event) => {
					if (event.repeat) return block(event);
					if (event.code === 'Escape' && recorded.size === 0) {
						block(event);
						return finish(null);
					}
					press(event, [keyNameFromCode(event.code)]);
				},
			],
			['keyup', release],
			// Named from `buttons` (not `button`, which swaps right and middle) to match Yomitan.
			['mousedown', (event) => press(event, mouseButtonNames(event.buttons))],
			['mouseup', release],
			['click', block],
			['auxclick', block],
			['contextmenu', block],
		];
		// Start listening after the click that started recording.
		let listening = false;
		setTimeout(() => {
			if (done) return;
			listening = true;
			for (const [type, listener] of listeners) window.addEventListener(type, listener, true);
		}, 0);
		// Buttons as seen by the app, which include ones WebKit never reports as mouse events (e.g. side
		// buttons whose press and release arrive together).
		const onNativeButton = (number, isDown) => {
			if (!listening || done || number > 5) return;
			if (isDown) {
				recorded.add(`mouse${number}`);
				button.textContent = formatScanInput([...recorded]);
			} else if (recorded.size > 0) {
				finish(formatScanInput([...recorded]));
			}
		};
		activeRecording = { cancel: () => finish(null), onNativeButton };
	});
}

function createScanInputsControl(field) {
	const control = document.createElement('div');
	control.className = 'flex flex-col gap-2';
	const list = document.createElement('div');
	list.className = 'flex flex-col gap-2 empty:hidden';
	const addButton = document.createElement('button');
	addButton.className = 'btn btn-sm self-start';
	addButton.textContent = 'Record new input';
	addButton.addEventListener('click', async () => {
		const value = await recordScanInput(addButton);
		if (value !== null) save(field, [...(getSettings()[field.key] ?? []), value]);
	});
	const hint = document.createElement('p');
	hint.className = 'text-xs opacity-70';
	hint.textContent = scanInputsHint;
	control.append(list, addButton, hint);

	const setValue = (values) => {
		list.replaceChildren(
			...values.map((value, index) => {
				const replaceAt = (newValue) => save(field, values.map((v, i) => (i === index ? newValue : v)));
				const row = document.createElement('div');
				row.className = 'flex items-center gap-2';
				const text = document.createElement('input');
				text.type = 'text';
				text.className = 'input input-bordered input-sm flex-1 min-w-0 font-mono';
				text.placeholder = 'hover';
				text.spellcheck = false;
				text.value = value;
				const validate = () => {
					const names = parseScanInput(text.value);
					const invalid = names.filter((name) => !isValidInputName(name));
					text.classList.toggle('input-error', invalid.length > 0);
					text.title = invalid.length > 0 ? `Not supported by Yomitan scan inputs: ${invalid.join(', ')}` : '';
					return invalid.length === 0 ? names : null;
				};
				validate();
				text.addEventListener('change', () => {
					const names = validate();
					if (names) replaceAt(formatScanInput(names));
				});
				const record = document.createElement('button');
				record.className = 'btn btn-sm';
				record.textContent = 'Record';
				record.addEventListener('click', async () => {
					const recorded = await recordScanInput(record);
					if (recorded !== null) replaceAt(recorded);
				});
				const remove = document.createElement('button');
				remove.className = 'btn btn-sm btn-ghost';
				remove.textContent = '✕';
				remove.title = 'Remove';
				remove.addEventListener('click', () => save(field, values.filter((_, i) => i !== index)));
				row.append(text, record, remove);
				return row;
			}),
		);
	};
	return { control, setValue };
}

// Summarizes a value copied by Import Yomitan, which is only edited in Yomitan, with a button to clear it.
function createImportedControl(field) {
	const control = document.createElement('div');
	control.className = 'flex flex-col gap-2';
	const setValue = (value) => {
		const isEmpty = value === null || (Array.isArray(value) && value.length === 0);
		const summary = document.createElement('p');
		summary.className = 'text-sm opacity-70';
		summary.textContent = isEmpty ? field.emptyText : field.describe(value);
		control.replaceChildren(summary);
		if (isEmpty) return;
		const clear = document.createElement('button');
		clear.className = 'btn btn-sm self-end';
		clear.textContent = 'Clear';
		clear.addEventListener('click', () => save(field, field.clearedValue));
		control.append(clear);
	};
	return { control, setValue };
}

// The handlebars templates in yomitanAnkiTemplates. Shows Yomitan's defaults until they're changed.
function createAnkiTemplatesControl(field) {
	const control = document.createElement('div');
	control.className = 'flex flex-col gap-2';
	const textarea = document.createElement('textarea');
	textarea.className = 'textarea textarea-bordered w-full text-xs leading-snug font-mono';
	textarea.rows = 12;
	textarea.spellcheck = false;
	const status = document.createElement('p');
	status.className = 'text-xs opacity-60';
	const reset = document.createElement('button');
	reset.className = 'btn btn-sm self-end';
	reset.textContent = 'Reset to Yomitan defaults';
	control.append(textarea, status, reset);

	// Settings from before an import keep the import's other values (dictionaries, output modes).
	const current = () => getSettings().yomitanAnkiTemplates ?? { fieldTemplates: null, dictionaries: [], resultOutputMode: 'group', readingMode: null };
	const saveTemplates = (fieldTemplates) => {
		const value = fieldTemplates === null || fieldTemplates.trim() === '' || fieldTemplates === defaultFieldTemplates ? null : fieldTemplates;
		save(field, { ...current(), fieldTemplates: value });
	};
	textarea.addEventListener('change', () => saveTemplates(textarea.value));
	reset.addEventListener('click', () => saveTemplates(null));

	const setValue = (value) => {
		const fieldTemplates = value && !Array.isArray(value) ? value.fieldTemplates : null;
		if (document.activeElement !== textarea) textarea.value = fieldTemplates ?? defaultFieldTemplates;
		status.textContent = fieldTemplates === null ? 'Yomitan’s default templates.' : 'Custom templates.';
		reset.hidden = fieldTemplates === null;
	};
	return { control, setValue };
}

// The window read in screen OCR mode, chosen on screen (see WindowPicker.swift).
function createOcrWindowControl() {
	const control = document.createElement('div');
	control.className = 'flex items-center gap-2';
	const description = document.createElement('span');
	description.className = 'text-sm truncate flex-1';
	const select = document.createElement('button');
	select.className = 'btn btn-sm';
	select.textContent = 'Select…';
	select.addEventListener('click', () => nativeCall('ocr', { action: 'select' }));
	control.append(description, select);

	const setValue = (value) => {
		const regions = getSettings().ocrRegions ?? [];
		if (!value || Array.isArray(value)) {
			description.textContent = 'None';
		} else {
			const name = value.title ? `${value.ownerName} — ${value.title}` : value.ownerName;
			description.textContent = `${name} (${regions.length === 0 ? 'whole window' : `${regions.length} area${regions.length === 1 ? '' : 's'}`})`;
		}
		description.title = description.textContent;
	};
	return { control, setValue };
}

function createField(field) {
	const label = document.createElement('span');
	label.className = 'label-text';
	label.textContent = field.label;
	if (field.hint) {
		const hint = document.createElement('span');
		hint.className = 'block text-xs opacity-60 mt-0.5';
		hint.textContent = field.hint;
		label.append(hint);
	}

	const customControls = {
		scanInputs: createScanInputsControl,
		imported: createImportedControl,
		ankiTemplates: createAnkiTemplatesControl,
		ocrWindow: createOcrWindowControl,
	};
	if (field.type in customControls) {
		const { control, setValue } = customControls[field.type](field);
		label.classList.add('self-start', 'pt-1');
		inputs.set(field.key, { field, input: control, setValue });
		return [label, control];
	}

	let input;
	switch (field.type) {
		case 'checkbox':
			input = document.createElement('input');
			input.type = 'checkbox';
			input.className = 'checkbox checkbox-primary justify-self-end';
			input.addEventListener('change', () => save(field, input.checked));
			break;
		case 'select':
			input = document.createElement('select');
			input.className = 'select select-bordered select-sm w-full';
			for (const { value, label: text } of field.options) {
				const element = document.createElement('option');
				element.value = value;
				element.textContent = text;
				input.append(element);
			}
			input.addEventListener('change', () => save(field, input.value));
			break;
		case 'textarea':
		case 'json':
		case 'lines':
			input = document.createElement('textarea');
			input.className = 'textarea textarea-bordered w-full text-sm leading-snug';
			input.rows = field.type === 'lines' ? 3 : 6;
			input.spellcheck = false;
			input.addEventListener('change', () => {
				if (field.type === 'lines') {
					save(field, input.value.split('\n').map((line) => line.trim()).filter(Boolean));
				} else if (field.type === 'json') {
					try {
						const value = JSON.parse(input.value || '[]');
						if (!Array.isArray(value)) throw new Error('Expected an array');
						input.classList.remove('textarea-error');
						save(field, value);
					} catch (_) {
						input.classList.add('textarea-error');
					}
				} else {
					save(field, input.value);
				}
			});
			break;
		default:
			input = document.createElement('input');
			input.type = field.type === 'number' ? 'number' : 'text';
			input.className = 'input input-bordered input-sm w-full min-w-0';
			if (field.min !== undefined) input.min = field.min;
			if (field.max !== undefined) input.max = field.max;
			if (field.step !== undefined) input.step = field.step;
			input.spellcheck = false;
			input.addEventListener('change', () => {
				if (field.type === 'number') {
					const value = Number.parseFloat(input.value);
					save(field, Number.isFinite(value) ? value : getSettings()[field.key]);
				} else {
					save(field, input.value.trim());
				}
			});
	}
	inputs.set(field.key, { field, input });

	if (field.type === 'textarea' || field.type === 'json' || field.type === 'lines') label.classList.add('self-start', 'pt-2');
	if (!field.test) return [label, input];

	const control = document.createElement('div');
	control.className = 'flex flex-col gap-1';
	const row = document.createElement('div');
	row.className = 'flex items-center gap-2';
	const button = document.createElement('button');
	button.className = 'btn btn-sm';
	button.textContent = 'Test';
	const status = document.createElement('span');
	status.className = 'text-xs truncate empty:hidden';
	button.addEventListener('click', async () => {
		status.textContent = '…';
		status.className = 'text-xs truncate empty:hidden';
		try {
			status.textContent = await field.test();
			status.classList.add('text-success');
		} catch (e) {
			status.textContent = e.message ?? `${e}`;
			status.classList.add('text-error');
		}
		status.title = status.textContent;
	});
	row.append(input, button);
	control.append(row, status);
	return [label, control];
}

function render() {
	const container = document.querySelector('#sections');
	for (const section of sections) {
		const card = document.createElement('section');
		card.className = 'bg-base-100 rounded-box p-4 shadow';
		const title = document.createElement('h2');
		title.className = 'text-lg font-semibold mb-1';
		title.textContent = section.title;
		card.append(title);
		if (section.description) {
			const description = document.createElement('p');
			description.className = 'text-sm opacity-70 mb-2';
			description.textContent = section.description;
			card.append(description);
		}
		const grid = document.createElement('div');
		grid.className = 'grid grid-cols-[minmax(0,1fr)_minmax(0,20rem)] gap-x-6 gap-y-3 items-center mt-2';
		for (const field of section.fields) {
			const elements = createField(field);
			if (field.showIf) conditionalFields.push({ field, elements });
			grid.append(...elements);
		}
		card.append(grid);
		container.append(card);
	}
}

function update(settings) {
	document.documentElement.dataset.theme = settings.theme;
	for (const { field, elements } of conditionalFields) {
		for (const element of elements) element.classList.toggle('hidden', !field.showIf(settings));
	}
	for (const [key, { field, input, setValue }] of inputs) {
		if (document.activeElement === input) continue;
		const value = settings[key];
		if (setValue) {
			// Don't rebuild a list while one of its fields is being edited.
			if (!(input.contains(document.activeElement) && document.activeElement.tagName === 'INPUT')) setValue(value ?? []);
			continue;
		}
		switch (field.type) {
			case 'checkbox':
				input.checked = !!value;
				break;
			case 'lines':
				input.value = (value ?? []).join('\n');
				break;
			case 'json':
				input.value = JSON.stringify(value ?? [], null, 2);
				break;
			default:
				input.value = value ?? '';
		}
	}
}

function save(field, value) {
	// Switching to custom starts from the simple mode that was selected.
	const customInputsKey = { scanModifier: 'scanInputs', popupScanModifier: 'popupScanInputs' }[field.key];
	if (customInputsKey && value === 'custom' && (getSettings()[customInputsKey] ?? []).length === 0) {
		const previous = getSettings()[field.key];
		void saveSettings({ [field.key]: value, [customInputsKey]: [previous === 'none' ? '' : previous] });
	} else {
		void saveSettings({ [field.key]: value });
	}
	update(getSettings());
}

async function testYomitan() {
	const { version } = await yomitanVersion();
	return `Connected (Yomitan ${version})`;
}

async function testAnki() {
	const version = await ankiInvoke('version');
	return `Connected (AnkiConnect v${version})`;
}

// texthooker-ui exports settings as {currentSettings: {fontSize$: 24, ...}, ...}.
function importTexthookerSettings(json) {
	const data = JSON.parse(json);
	const source = data.currentSettings ?? data;
	const result = {};
	for (const [rawKey, value] of Object.entries(source)) {
		const key = rawKey.replace(/\$$/, '');
		if (key in getSettings() && !['websocketUrls'].includes(key)) result[key] = value;
	}
	const urls = [source.websocketUrl$, source.secondaryWebsocketUrl$].filter((url) => typeof url === 'string' && url.length > 0);
	if (urls.length > 0) result.websocketUrls = urls;
	return result;
}

/** Resolves to the chosen profile index, or null if cancelled. */
function chooseProfile(profiles, profileCurrent) {
	const dialog = document.querySelector('#profile-dialog');
	const select = dialog.querySelector('select');
	select.replaceChildren(
		...profiles.map((name, i) => {
			const element = document.createElement('option');
			element.value = `${i}`;
			element.textContent = i === profileCurrent ? `${name} (current)` : name;
			return element;
		}),
	);
	select.value = `${profileCurrent}`;
	return new Promise((resolve) => {
		dialog.addEventListener('close', () => resolve(dialog.returnValue === 'import' ? Number(select.value) : null), { once: true });
		dialog.showModal();
	});
}

async function main() {
	render();
	update(await loadSettings());
	onSettingsChanged(update);

	const fileInput = document.querySelector('#import-file');
	document.querySelector('#import-texthooker').addEventListener('click', () => fileInput.click());
	fileInput.addEventListener('change', async () => {
		const [file] = fileInput.files;
		fileInput.value = '';
		if (!file) return;
		try {
			const imported = importTexthookerSettings(await file.text());
			await saveSettings(imported);
			update(getSettings());
			alert(`Imported ${Object.keys(imported).length} settings.`);
		} catch (e) {
			alert(`Import failed: ${e.message ?? e}`);
		}
	});
	const yomitanFileInput = document.querySelector('#import-yomitan-file');
	document.querySelector('#import-yomitan').addEventListener('click', () => yomitanFileInput.click());
	yomitanFileInput.addEventListener('change', async () => {
		const [file] = yomitanFileInput.files;
		yomitanFileInput.value = '';
		if (!file) return;
		try {
			const { options, profiles, profileCurrent } = parseYomitanExport(await file.text());
			const profileIndex = profiles.length > 1 ? await chooseProfile(profiles, profileCurrent) : 0;
			if (profileIndex === null) return;
			const imported = convertYomitanProfile(options, profileIndex, getSettings());
			await saveSettings(imported);
			update(getSettings());
			alert(`Imported ${Object.keys(imported).length} settings from the Yomitan profile “${profiles[profileIndex]}”.`);
		} catch (e) {
			alert(`Import failed: ${e.message ?? e}`);
		}
	});
	document.querySelector('#reset').addEventListener('click', async () => {
		if (confirm('Reset all settings to their defaults?')) {
			await resetSettings();
			update(getSettings());
		}
	});
}

main().catch((e) => log('Settings failed to start', e));
