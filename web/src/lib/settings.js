import { defaultSettings } from './settings-defaults.js';
import { nativeCall } from './native.js';

// The stored settings, and those over them that the Yomitan profile gives (see setYomitanSettings): getSettings has
// both, and saveSettings saves only the first.
let stored = { ...defaultSettings };
let fromYomitan = { always: {}, display: {} };
let current = stored;
const listeners = new Set();

function merge(settings) {
	return { ...defaultSettings, ...(settings || {}) };
}

function update(settings) {
	stored = settings;
	current = { ...stored, ...fromYomitan.always, ...(stored.useYomitanDisplay ? fromYomitan.display : {}) };
	// The profile's dictionaries and grouping, with the field templates set in MacPopup.
	if (fromYomitan.always.yomitanAnkiTemplates) {
		current.yomitanAnkiTemplates = { fieldTemplates: null, ...stored.yomitanAnkiTemplates, ...fromYomitan.always.yomitanAnkiTemplates };
	}
}

export async function loadSettings() {
	// Called by the host whenever any window saves settings. Installed first so no update is missed.
	let updated = false;
	window.__macpopupSettingsChanged = (settings) => {
		updated = true;
		update(merge(settings));
		for (const listener of listeners) listener(current);
	};
	try {
		const settings = merge(JSON.parse((await nativeCall('getSettings')) || '{}'));
		if (!updated) update(settings);
	} catch (_) {
		// Keep the defaults.
	}
	return current;
}

export function getSettings() {
	return current;
}

/** Popups receive settings from the overlay instead of the host (with Yomitan's, and never save them). */
export function setLocalSettings(settings) {
	update(merge(settings));
	for (const listener of listeners) listener(current);
}

/**
 * Settings the Yomitan profile gives through its API (see lib/yomitan-profile.js), over the stored ones: `always`,
 * and `display` with "Use Yomitan's display settings" on. Listeners aren't told.
 */
export function setYomitanSettings({ always = {}, display = {} } = {}) {
	fromYomitan = { always, display };
	update(stored);
}

export function onSettingsChanged(listener) {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

/** A popup theme setting as the theme it shows: "site" is the page's (`siteTheme`), "browser" the system's. */
export function resolveTheme(theme, siteTheme) {
	if (theme === 'site') return siteTheme;
	if (theme === 'browser') return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
	return theme;
}

export async function saveSettings(partial) {
	update({ ...stored, ...partial });
	await nativeCall('setSettings', { json: JSON.stringify(stored) });
}
