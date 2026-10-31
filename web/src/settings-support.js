// The settings logic the native Settings window (SettingsSupport.swift) shares with the web pages:
// it runs this bundle in JavaScriptCore, so the defaults and the imports exist only once.
// Values cross over as JSON strings.

import defaultFieldTemplates from '../../vendor/yomitan/ext/data/templates/default-anki-field-templates.handlebars';
import { defaultSettings, onlineFonts, themes } from './lib/settings-defaults.js';
import { languageSummaries } from './lib/languages.js';
import { applyReplacements, patternError } from './lib/replacements.js';
import { importTexthookerSettings } from './lib/texthooker-import.js';
import { convertYomitanProfile, parseYomitanExport } from './lib/yomitan-import.js';

export { defaultFieldTemplates, onlineFonts, themes };

/** Yomitan's languages for the Language menu: [{iso, name}]. */
export const languages = languageSummaries.map(({ iso, name }) => ({ iso, name }));

export function defaultsJSON() {
	return JSON.stringify(defaultSettings);
}

/** The profiles in a Yomitan settings export: {profiles: string[], profileCurrent}. */
export function yomitanProfiles(json) {
	const { profiles, profileCurrent } = parseYomitanExport(json);
	return JSON.stringify({ profiles, profileCurrent });
}

export function convertYomitan(json, profileIndex, currentSettingsJSON) {
	const { options } = parseYomitanExport(json);
	return JSON.stringify(convertYomitanProfile(options, profileIndex, JSON.parse(currentSettingsJSON)));
}

/** `text` with the replacements applied, as on lines. */
export function previewReplacements(text, replacementsJSON) {
	return applyReplacements(text, JSON.parse(replacementsJSON));
}

export { patternError };

export function convertTexthooker(json, currentSettingsJSON) {
	return JSON.stringify(importTexthookerSettings(json, JSON.parse(currentSettingsJSON)));
}
