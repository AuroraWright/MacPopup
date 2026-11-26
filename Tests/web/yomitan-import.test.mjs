// Importing a Yomitan settings export (lib/yomitan-import.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseYomitanExport, convertYomitanApiProfile, convertYomitanProfile } from '../../web/src/lib/yomitan-import.js';
import { defaultSettings } from '../../web/src/lib/settings-defaults.js';

/** An export with these profiles ({name?, options, conditionGroups?}), as Yomitan wraps it. */
function exported(profiles, profileCurrent = 0) {
	return JSON.stringify({ version: 1, date: '2026-11-26', options: { profileCurrent, profiles } });
}

/** The MacPopup settings from a one-profile export with these options. */
function converted(options) {
	const parsed = parseYomitanExport(exported([{ name: 'Default', options }]));
	return convertYomitanProfile(parsed.options, 0, defaultSettings);
}

/** An input of the profile's scanning.inputs. */
function input(include, { exclude = '', mouse = true, searchTerms = true, searchKanji = true } = {}) {
	return { include, exclude, types: { mouse, touch: true, pen: true }, options: { searchTerms, searchKanji } };
}

test('profiles are named, the current one kept when it exists', () => {
	const options = { general: {} };
	assert.deepEqual(parseYomitanExport(exported([{ name: 'Default', options }, { options }], 1)).profiles, ['Default', 'Profile 2']);
	assert.equal(parseYomitanExport(exported([{ options }], 1)).profileCurrent, 0);
	// An export of the options only, without Yomitan's wrapper.
	assert.equal(parseYomitanExport(JSON.stringify({ profileCurrent: 0, profiles: [{ name: 'Bare', options }] })).profiles[0], 'Bare');
	assert.throws(() => parseYomitanExport(exported([])), /no profiles/);
});

test('options MacPopup has are copied under its names, unless their type differs', () => {
	const result = converted({
		general: { popupWidth: 500, popupHeight: '300', fontSize: 18, yomitanApiServer: 'http://127.0.0.1:19634', enableWanakana: true },
		scanning: { length: 20, delay: null },
		clipboard: { enableBackgroundMonitor: true },
		parsing: { readingMode: 'katakana', termSpacing: false },
	});
	assert.equal(result.popupWidth, 500);
	assert.equal(result.popupFontSize, 18);
	assert.equal(result.yomitanApiUrl, 'http://127.0.0.1:19634');
	assert.equal(result.scanLength, 20);
	assert.equal(result.clipboardMonitor, true);
	assert.equal(result.furiganaReadingMode, 'katakana');
	assert.equal(result.termSpacing, false);
	assert.equal('popupHeight' in result, false, 'a height that isn\'t a number');
	assert.equal('scanDelay' in result, false, 'a null delay');
	assert.equal('enableWanakana' in result, false, 'an option MacPopup doesn\'t have');
});

test('the language and parser are imported when MacPopup has them', () => {
	assert.equal(converted({ general: { language: 'en' } }).language, 'en');
	assert.equal('language' in converted({ general: { language: 'tlh' } }), false);
	assert.equal(converted({ parsing: { selectedParser: 'scan' } }).parser, 'scanning-parser');
	assert.equal(converted({ parsing: { selectedParser: 'mecab-ipadic' } }).parser, 'mecab');
	assert.equal('parser' in converted({ parsing: { selectedParser: null } }), false);
});

test('Anki\'s tags, screenshot and templates are imported, with the enabled dictionaries', () => {
	const result = converted({
		anki: { tags: ['yomitan', 'game'], targetTags: ['mined'], screenshot: { format: 'jpeg', quality: 80 }, fieldTemplates: '{{#*inline "x"}}{{/inline}}' },
		dictionaries: [{ name: 'JMdict', enabled: true }, { name: 'Off', enabled: false }],
	});
	assert.equal(result.ankiTags, 'yomitan game');
	assert.equal(result.ankiTargetTags, 'mined');
	assert.equal(result.screenshotFormat, 'jpeg');
	assert.equal(result.screenshotQuality, 80);
	assert.deepEqual(result.yomitanAnkiTemplates,
		{ fieldTemplates: '{{#*inline "x"}}{{/inline}}', dictionaries: ['JMdict'], resultOutputMode: 'group' });
	assert.equal(converted({ anki: {}, general: { resultOutputMode: 'split' } }).yomitanAnkiTemplates.fieldTemplates, null);
	assert.equal(converted({ anki: {}, general: { resultOutputMode: 'split' } }).yomitanAnkiTemplates.resultOutputMode, 'split');
	assert.equal('yomitanAnkiTemplates' in converted({ general: {} }), false);
});

test('audio sources are imported with their fields, the ones without a type skipped', () => {
	assert.deepEqual(converted({ audio: { sources: [{ type: 'jpod101' }, { type: 'custom', url: 'http://localhost/{term}', voice: 3 }, { url: 'x' }] } }).audioSources, [
		{ type: 'jpod101', url: '', voice: '', apiKey: '' },
		{ type: 'custom', url: 'http://localhost/{term}', voice: '', apiKey: '' },
	]);
});

test('popup back and forward is imported', () => {
	assert.equal(converted({ scanning: { preventBackForward: { onPopupPages: true } } }).preventBackForwardInPopups, true);
	assert.equal('preventBackForwardInPopups' in converted({ scanning: {} }), false);
});

test('the enabled dictionaries\' collapse modes and styles are imported', () => {
	const result = converted({ dictionaries: [
		{ name: 'JMdict', enabled: true, definitionsCollapsible: 'expanded', styles: '.gloss { color: red; }' },
		{ name: 'Pitch', enabled: true, definitionsCollapsible: 'not-collapsible', styles: '  ' },
		{ name: 'Off', enabled: false, definitionsCollapsible: 'collapsed', styles: 'b {}' },
	] });
	assert.deepEqual(result.dictionaryCollapsible, [{ name: 'JMdict', mode: 'expanded' }, { name: 'Pitch', mode: 'not-collapsible' }]);
	assert.deepEqual(result.dictionaryStyles, [{ name: 'JMdict', styles: '.gloss { color: red; }' }]);
});

test('scan inputs: hover, a single modifier, or a custom list', () => {
	const scan = (inputs) => {
		const result = converted({ scanning: { inputs } });
		return [result.scanModifier, result.scanInputs];
	};
	assert.deepEqual(scan([input('')]), ['none', undefined]);
	assert.deepEqual(scan([input('shift')]), ['shift', undefined]);
	assert.deepEqual(scan([input('mouse1 ctrl'), input('alt', { exclude: 'shift', searchTerms: false })]), ['custom', ['ctrl mouse1', 'alt -shift kanji']]);
	// Inputs for other pointers, with names MacPopup doesn't know, or that look up nothing are left out.
	assert.deepEqual(scan([input('shift', { mouse: false }), input('fn'), input('alt', { searchTerms: false, searchKanji: false }), input('meta')]), ['meta', undefined]);
	assert.deepEqual(scan([input('fn')]), [undefined, undefined]);
});

test('scanning in popups follows the profile Yomitan uses for nested popups', () => {
	const main = { name: 'Main', options: { scanning: { inputs: [input('')] } } };
	const nested = {
		name: 'Nested', options: { scanning: { inputs: [input('alt')] } },
		conditionGroups: [{ conditions: [{ type: 'popupLevel', operator: 'greaterThan', value: '0' }] }],
	};
	const result = (profiles, chosen) => {
		const parsed = parseYomitanExport(exported(profiles));
		const settings = convertYomitanProfile(parsed.options, chosen, defaultSettings);
		return [settings.scanModifier, settings.popupScanModifier];
	};
	assert.deepEqual(result([main, nested], 0), ['none', 'alt']);
	// Not when its condition doesn't hold in popups: the current profile then.
	const top = { ...nested, conditionGroups: [{ conditions: [{ type: 'popupLevel', operator: 'equal', value: '0' }] }] };
	assert.deepEqual(result([main, top], 0), ['none', 'none']);
	// A URL condition holds for the profile chosen only.
	const site = { ...nested, conditionGroups: [{ conditions: [{ type: 'url', operator: 'matchDomain', value: 'example.com' }] }] };
	assert.deepEqual(result([main, site], 0), ['none', 'none']);
	assert.deepEqual(result([main, site], 1), ['alt', 'alt']);
});

test('a Yomitan API profile gives the dictionaries, and the display options MacPopup has', () => {
	const dictionaryInfo = [
		{ title: 'JMdict', styles: '.gloss {}', options: { enabled: true, definitionsCollapsible: 'collapsed' } },
		{ title: 'Off', styles: '', options: { enabled: false } },
		{ title: 'Not in profile', styles: '', options: null },
	];
	const { always, display } = convertYomitanApiProfile(
		{ general: { popupWidth: 450, popupTheme: 'dark', resultOutputMode: 'merge', enableWanakana: true }, scanning: { length: 12 } },
		dictionaryInfo, defaultSettings,
	);
	assert.deepEqual(always.dictionaryCollapsible, [{ name: 'JMdict', mode: 'collapsed' }]);
	assert.deepEqual(always.dictionaryStyles, [{ name: 'JMdict', styles: '.gloss {}' }]);
	assert.deepEqual(always.yomitanAnkiTemplates, { dictionaries: ['JMdict'], resultOutputMode: 'merge' });
	assert.equal(always.yomitanDictionaryInfo, dictionaryInfo);
	assert.deepEqual(display, { popupWidth: 450, popupTheme: 'dark', scanLength: 12 });
});

test('popup hotkeys are imported, without the ones MacPopup has no action for', () => {
	const hotkeys = [
		{ action: 'toggleOption', argument: 'general.enableWanakana', key: 'KeyT', modifiers: ['alt'], scopes: ['popup'], enabled: true },
		{ action: 'addNote', argument: '0', key: 'KeyE', modifiers: ['alt'], scopes: ['popup'], enabled: true },
	];
	assert.deepEqual(converted({ inputs: { hotkeys }, general: {}, scanning: {}, anki: {}, audio: {} }).hotkeys,
		[{ action: 'addNote', argument: '0', key: 'KeyE', modifiers: ['alt'], enabled: true }]);
});
