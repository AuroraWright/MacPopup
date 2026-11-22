// The Yomitan profile's display options and dictionaries, through the API paths displayOptions and dictionaryInfo,
// over MacPopup's settings (see setYomitanSettings in settings.js). Only a Yomitan with yomitan-api-endpoints.patch has
// them: an older one answers 400, and MacPopup's settings and what Import → Yomitan Settings copied are used, as
// before (asked again now and then, in case Yomitan was updated).
import { dictionaryInfo, displayOptions } from './yomitan-api.js';
import { convertYomitanApiProfile } from './yomitan-import.js';
import { getSettings, setYomitanSettings } from './settings.js';

// How long a reading of the profile is used before it's read again (when a popup opens), and how long until a Yomitan
// without the paths is asked again.
const maxAge = 5000;
const unsupportedMaxAge = 60000;

let url = null;
/** Whether the API has the paths, as it last answered. */
let supported = null;
/** Whether it has been asked since its URL was set (and answered or failed). */
let asked = false;
let time = 0;
let pending = null;
let profile = null;
let onChange = () => {};

/** `changed` is called when what the profile gives changes, after the settings have it. */
export function watchYomitanProfile(changed) {
	onChange = changed;
}

/**
 * Reads the profile again if the last reading is old. Lookups don't wait for it, except the first ones before it was
 * asked (see yomitanProfileAsked): those can wait for the returned promise.
 */
export function refreshYomitanProfile() {
	const { yomitanApiUrl } = getSettings();
	if (yomitanApiUrl !== url) {
		url = yomitanApiUrl;
		supported = null;
		asked = false;
		time = 0;
		apply(null);
	}
	if (pending) return pending;
	if (Date.now() - time < (supported === false ? unsupportedMaxAge : maxAge)) return Promise.resolve();
	const requestUrl = url;
	pending = Promise.all([displayOptions(), dictionaryInfo()])
		.then(([options, dictionaries]) => {
			if (requestUrl !== url) return;
			supported = true;
			time = Date.now();
			apply({ options, dictionaries });
		})
		.catch((e) => {
			if (requestUrl !== url) return;
			time = Date.now();
			// After any other failure (the API not running, a slow answer), the last reading stays until it's asked again.
			if (e?.status === 400) {
				supported = false;
				apply(null);
			}
		})
		.finally(() => {
			if (requestUrl === url) asked = true;
			pending = null;
		});
	return pending;
}

/** Whether the API was asked for the profile since its URL was set, whatever it answered. */
export function yomitanProfileAsked() {
	return asked;
}

function apply(next) {
	const key = JSON.stringify(next);
	if (key === JSON.stringify(profile)) return;
	profile = next;
	setYomitanSettings(next ? convertYomitanApiProfile(next.options, next.dictionaries, getSettings()) : undefined);
	onChange();
}
