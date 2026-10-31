// Adapts CSS written for Chrome and Firefox (dictionary styles, Yomitan popup CSS) to WebKit.

export function adaptCssForWebKit(css) {
	return addWebKitDetailsMarkerRules(addWebKitUserSelect(css));
}

// WebKit only supports user-select with its prefix, e.g. for `.tag { user-select: all }`, which
// makes a click select a whole dictionary name.
function addWebKitUserSelect(css) {
	return css.replace(/(^|[{;\s])user-select(\s*:\s*[^;{}]+)/g, '$1user-select$2;-webkit-user-select$2');
}

// WebKit ignores `content` in ::marker, so the `summary::marker { content: "" }` rules that
// dictionaries and popup CSS use to hide the disclosure triangle in Chrome and Firefox don't work.
// This hides it with `list-style: none` instead, and with ::-webkit-details-marker for older WebKit.

const hidesMarker = /(?:^|;)\s*content\s*:\s*(?:""|''|none)\s*(?:!important\s*)?(?:;|$)/;
const hidesListStyle = /(?:^|;)\s*list-style(?:-type)?\s*:\s*none\s*(?:!important\s*)?(?:;|$)/;

function addWebKitDetailsMarkerRules(css) {
	const selectors = new Set();
	for (const [, selectorList, body] of css.matchAll(/([^{};]+)\{([^{}]*)\}/g)) {
		for (const selector of selectorList.split(',').map((part) => part.trim())) {
			const marker = /^(.*\bsummary)::marker$/.exec(selector);
			if (marker && hidesMarker.test(body)) selectors.add(marker[1]);
			else if (/\bsummary$/.test(selector) && hidesListStyle.test(body)) selectors.add(selector);
		}
	}
	if (selectors.size === 0) return css;
	const list = [...selectors];
	return `${css}
${list.join(',\n')} { list-style: none; }
${list.map((selector) => `${selector}::-webkit-details-marker`).join(',\n')} { display: none; }`;
}
