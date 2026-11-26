// texthooker-ui settings exports (lib/texthooker-import.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importTexthookerSettings } from '../../web/src/lib/texthooker-import.js';
import { defaultSettings } from '../../web/src/lib/settings-defaults.js';

const imported = (settings) => importTexthookerSettings(JSON.stringify({ currentSettings: settings }), defaultSettings);

test('the settings MacPopup has are imported without their $, the others skipped', () => {
	assert.deepEqual(imported({ theme$: 'dark', maxLines$: 50, preventGlobalDuplicate$: true, enableExternalClipboardMonitor$: true }),
		{ theme: 'dark', maxLines: 50, preventGlobalDuplicate: true });
});

test('an export without its currentSettings wrapper is imported too', () => {
	assert.deepEqual(importTexthookerSettings(JSON.stringify({ fontSize$: 30 }), defaultSettings), { fontSize: 30 });
});

test('numbers older versions saved as text are imported as numbers, and text that isn\'t one is skipped', () => {
	assert.deepEqual(imported({ fontSize$: '30', maxLines$: 'many', preventLastDuplicate$: ' ' }), { fontSize: 30 });
});

test('line padding goes from rem to pixels', () => {
	assert.equal(imported({ linePadding$: 0.5 }).linePadding, 8);
	assert.equal(imported({ linePadding$: '1' }).linePadding, 16);
});

test('the WebSocket URLs become the list, without empty ones', () => {
	assert.deepEqual(imported({ websocketUrl$: 'ws://localhost:6677', secondaryWebsocketUrl$: 'ws://localhost:9001' }).websocketUrls,
		['ws://localhost:6677', 'ws://localhost:9001']);
	assert.deepEqual(imported({ websocketUrl$: 'ws://localhost:6677', secondaryWebsocketUrl$: '' }).websocketUrls, ['ws://localhost:6677']);
	assert.equal('websocketUrls' in imported({ websocketUrl$: '', websocketUrls$: ['ws://localhost:1'] }), false);
});

test('"Store Lines persistently" is "Keep lines after quitting"', () => {
	assert.equal(imported({ persistLines$: true }).floatingWindowKeepLines, true);
	assert.equal(imported({ persistLines$: false }).floatingWindowKeepLines, false);
	assert.equal('floatingWindowKeepLines' in imported({ fontSize$: 24 }), false);
});
