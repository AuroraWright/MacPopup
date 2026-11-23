// Importing a Yomitan settings export (lib/yomitan-import.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseYomitanExport, convertYomitanProfile } from '../../web/src/lib/yomitan-import.js';

function exported(hotkeys) {
	return JSON.stringify({
		options: {
			profileCurrent: 0,
			profiles: [{ name: 'Default', options: { inputs: { hotkeys }, general: {}, scanning: {}, anki: {}, audio: {} } }],
		},
	});
}

test('popup hotkeys are imported, without the ones MacPopup has no action for', () => {
	const parsed = parseYomitanExport(exported([
		{ action: 'toggleOption', argument: 'general.enableWanakana', key: 'KeyT', modifiers: ['alt'], scopes: ['popup'], enabled: true },
		{ action: 'addNote', argument: '0', key: 'KeyE', modifiers: ['alt'], scopes: ['popup'], enabled: true },
	]));
	assert.deepEqual(convertYomitanProfile(parsed.options, 0, {}).hotkeys,
		[{ action: 'addNote', argument: '0', key: 'KeyE', modifiers: ['alt'], enabled: true }]);
});
