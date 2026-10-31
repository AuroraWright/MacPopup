import { defaultSettings } from './settings-defaults.js';
import { nativeCall } from './native.js';

let current = { ...defaultSettings };
const listeners = new Set();

function merge(stored) {
	return { ...defaultSettings, ...(stored || {}) };
}

export async function loadSettings() {
	// Called by the host whenever any window saves settings. Installed first so no update is missed.
	let updated = false;
	window.__macpopupSettingsChanged = (stored) => {
		updated = true;
		current = merge(stored);
		for (const listener of listeners) listener(current);
	};
	try {
		const stored = merge(JSON.parse((await nativeCall('getSettings')) || '{}'));
		if (!updated) current = stored;
	} catch (_) {
		// Keep the defaults.
	}
	return current;
}

export function getSettings() {
	return current;
}

/** Popups receive settings from the overlay instead of the host. */
export function setLocalSettings(settings) {
	current = merge(settings);
	for (const listener of listeners) listener(current);
}

export function onSettingsChanged(listener) {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

export async function saveSettings(partial) {
	current = { ...current, ...partial };
	await nativeCall('setSettings', { json: JSON.stringify(current) });
}

export async function resetSettings() {
	current = merge(null);
	await nativeCall('setSettings', { json: '{}' });
}
