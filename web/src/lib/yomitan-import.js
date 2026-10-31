// Converts a Yomitan settings export (Settings → Backup → Export Settings) into MacPopup settings.

import { formatScanInput, isValidInputName, parseScanInput } from './scan-inputs.js';

const scanModifiers = new Set(['shift', 'ctrl', 'alt', 'meta']);

// Yomitan profile option → MacPopup setting, for options that are copied as-is.
const directOptions = {
	general: {
		popupWidth: 'popupWidth',
		popupHeight: 'popupHeight',
		popupHorizontalOffset: 'popupHorizontalOffset',
		popupVerticalOffset: 'popupVerticalOffset',
		popupHorizontalOffset2: 'popupHorizontalOffset2',
		popupVerticalOffset2: 'popupVerticalOffset2',
		popupHorizontalTextPosition: 'popupHorizontalTextPosition',
		popupVerticalTextPosition: 'popupVerticalTextPosition',
		popupScalingFactor: 'popupScalingFactor',
		popupDisplayMode: 'popupDisplayMode',
		popupTheme: 'popupTheme',
		popupOuterTheme: 'popupOuterTheme',
		fontFamily: 'fontFamily',
		fontSize: 'popupFontSize',
		lineHeight: 'lineHeight',
		glossaryLayoutMode: 'glossaryLayoutMode',
		compactTags: 'compactTags',
		averageFrequency: 'averageFrequency',
		frequencyDisplayMode: 'frequencyDisplayMode',
		termDisplayMode: 'termDisplayMode',
		showPitchAccentDownstepNotation: 'showPitchAccentDownstepNotation',
		showPitchAccentPositionNotation: 'showPitchAccentPositionNotation',
		showPitchAccentGraph: 'showPitchAccentGraph',
		popupCurrentIndicatorMode: 'popupCurrentIndicatorMode',
		popupActionBarVisibility: 'popupActionBarVisibility',
		popupActionBarLocation: 'popupActionBarLocation',
		customPopupCss: 'customPopupCss',
		customPopupOuterCss: 'customPopupOuterCss',
		yomitanApiServer: 'yomitanApiUrl',
	},
	scanning: {
		length: 'scanLength',
		delay: 'scanDelay',
		autoHideResults: 'autoHideResults',
		hideDelay: 'hideDelay',
		hidePopupOnCursorExit: 'hidePopupOnCursorExit',
		hidePopupOnCursorExitDelay: 'hidePopupOnCursorExitDelay',
	},
	sentenceParsing: {
		scanExtent: 'sentenceScanExtent',
		terminationCharacterMode: 'sentenceTerminationCharacterMode',
		terminationCharacters: 'sentenceTerminationCharacters',
	},
	audio: {
		autoPlay: 'audioAutoPlay',
	},
	anki: {
		enable: 'ankiEnabled',
		server: 'ankiConnectUrl',
		apiKey: 'ankiConnectKey',
		checkForDuplicates: 'checkForDuplicates',
		duplicateScope: 'duplicateScope',
		duplicateScopeCheckAllModels: 'duplicateScopeCheckAllModels',
		duplicateBehavior: 'duplicateBehavior',
		noteGuiMode: 'noteGuiMode',
	},
};

/**
 * @param {string} json The contents of an exported Yomitan settings file.
 * @returns {{profiles: string[], profileCurrent: number}}
 */
export function parseYomitanExport(json) {
	const data = JSON.parse(json);
	// Exports wrap the options in {version, date, environment, ..., options}.
	const options = data?.options?.profiles ? data.options : data;
	if (!Array.isArray(options?.profiles) || options.profiles.length === 0) {
		throw new Error('Not a Yomitan settings export (no profiles found).');
	}
	const profileCurrent = Number.isInteger(options.profileCurrent) && options.profileCurrent < options.profiles.length ? options.profileCurrent : 0;
	return { options, profiles: options.profiles.map((profile, i) => profile.name || `Profile ${i + 1}`), profileCurrent };
}

/**
 * MacPopup's scan mode for Yomitan's mouse scan inputs: a simple modifier (or 'none' for hover)
 * when that's all the profile uses, otherwise 'custom' with one entry per input.
 * @returns {{mode: string, inputs?: string[]} | undefined}
 */
function getScanInputs(inputs) {
	if (!Array.isArray(inputs)) return undefined;
	const usable = inputs
		.filter(({ include, types }) => types?.mouse !== false && typeof include === 'string')
		.map(({ include }) => parseScanInput(include))
		.filter((names) => names.every(isValidInputName));
	if (usable.length === 0) return undefined;
	if (usable.length === 1 && usable[0].length === 0) return { mode: 'none' };
	if (usable.length === 1 && usable[0].length === 1 && scanModifiers.has(usable[0][0])) return { mode: usable[0][0] };
	return { mode: 'custom', inputs: usable.map(formatScanInput) };
}

function popupLevelMatches(operator, value, depth) {
	const level = Number.parseInt(value, 10);
	switch (operator) {
		case 'equal': return depth === level;
		case 'notEqual': return depth !== level;
		case 'lessThan': return depth < level;
		case 'greaterThan': return depth > level;
		case 'lessThanOrEqual': return depth <= level;
		case 'greaterThanOrEqual': return depth >= level;
		default: return true;
	}
}

/**
 * The profile Yomitan would use inside popups at `depth`, following its profile conditions: the
 * first profile with a matching condition group, otherwise the current profile. URL conditions
 * are assumed to hold only for the chosen profile, which is the one meant for this text, and
 * conditions on modifier keys or flags never hold.
 */
function getProfileIndexForDepth(options, chosenIndex, depth) {
	for (const [index, profile] of options.profiles.entries()) {
		const groups = Array.isArray(profile.conditionGroups) ? profile.conditionGroups : [];
		if (groups.length === 0) continue;
		const conditionMatches = ({ type, operator, value }) => {
			switch (type) {
				case 'popupLevel': return popupLevelMatches(operator, value, depth);
				case 'url': return index === chosenIndex;
				default: return false;
			}
		};
		// Like Yomitan, groups without conditions are ignored, and a profile with only empty groups always matches.
		const nonEmpty = groups.filter(({ conditions }) => Array.isArray(conditions) && conditions.length > 0);
		if (nonEmpty.length === 0 || nonEmpty.some(({ conditions }) => conditions.every(conditionMatches))) return index;
	}
	return options.profileCurrent ?? 0;
}

/**
 * @param {object} options The `options` returned by parseYomitanExport.
 * @param {number} profileIndex
 * @param {object} currentSettings Used to skip values MacPopup doesn't know.
 * @returns {object} The MacPopup settings to save.
 */
export function convertYomitanProfile(options, profileIndex, currentSettings) {
	const profileOptions = options.profiles[profileIndex]?.options ?? {};
	const result = {};
	for (const [section, mapping] of Object.entries(directOptions)) {
		const source = profileOptions[section];
		if (typeof source !== 'object' || source === null) continue;
		for (const [from, to] of Object.entries(mapping)) {
			const value = source[from];
			const current = currentSettings[to];
			if (value === undefined || value === null) continue;
			if (Array.isArray(current) !== Array.isArray(value)) continue;
			if (!Array.isArray(current) && typeof current !== typeof value) continue;
			result[to] = value;
		}
	}

	const anki = profileOptions.anki ?? {};
	if (Array.isArray(anki.tags)) result.ankiTags = anki.tags.join(' ');
	if (anki.screenshot?.format) result.screenshotFormat = anki.screenshot.format;
	if (typeof anki.screenshot?.quality === 'number') result.screenshotQuality = anki.screenshot.quality;

	// Dictionary styles are only stored in Yomitan's settings; the API doesn't provide them.
	if (Array.isArray(profileOptions.dictionaries)) {
		result.dictionaryStyles = profileOptions.dictionaries
			.filter(({ name, enabled, styles }) => enabled && typeof name === 'string' && typeof styles === 'string' && styles.trim() !== '')
			.map(({ name, styles }) => ({ name, styles }));
	}

	if (typeof profileOptions.anki === 'object' && profileOptions.anki !== null) {
		const fieldTemplates = profileOptions.anki.fieldTemplates;
		result.yomitanAnkiTemplates = {
			fieldTemplates: typeof fieldTemplates === 'string' ? fieldTemplates : null,
			dictionaries: (profileOptions.dictionaries ?? []).filter(({ enabled, name }) => enabled && typeof name === 'string').map(({ name }) => name),
			resultOutputMode: profileOptions.general?.resultOutputMode ?? 'group',
			readingMode: profileOptions.parsing?.readingMode ?? null,
		};
	}

	const scan = getScanInputs(profileOptions.scanning?.inputs);
	if (scan) {
		result.scanModifier = scan.mode;
		if (scan.inputs) result.scanInputs = scan.inputs;
	}

	// Scanning inside popups can use a different profile, e.g. one limited to popup level 0.
	const popupProfileIndex = getProfileIndexForDepth(options, profileIndex, 1);
	const popupScan = getScanInputs(options.profiles[popupProfileIndex]?.options?.scanning?.inputs);
	if (popupScan) {
		result.popupScanModifier = popupScan.mode;
		if (popupScan.inputs) result.popupScanInputs = popupScan.inputs;
	}

	return result;
}
