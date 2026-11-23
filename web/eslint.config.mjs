// ESLint for the pages' scripts, the build scripts and the IINA plugin (npm run lint): its recommended rules only, the
// mistakes plain JavaScript has no compiler to catch (undefined names, unreachable code, duplicate keys…), not style.
// Run from the repo's root (see package.json), so that paths are relative to it.
import js from '@eslint/js';
import globals from 'globals';

export default [
	js.configs.recommended,
	{
		languageOptions: { ecmaVersion: 'latest', sourceType: 'module' },
		rules: {
			// _ for what a signature or a destructuring needs but the code doesn't use.
			'no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' }],
			// Failures that don't matter (e.g. storage the page can't use) are caught with nothing to do.
			'no-empty': ['error', { allowEmptyCatch: true }],
			// Comments about Japanese text show its spaces (e.g. U+3000).
			'no-irregular-whitespace': ['error', { skipComments: true }],
		},
	},
	{ files: ['web/src/**'], languageOptions: { globals: { ...globals.browser, webkit: 'readonly' } } },
	{ files: ['web/src/viewer/sw.js'], languageOptions: { globals: globals.serviceworker } },
	{ files: ['web/*.mjs', 'web/*.cjs'], languageOptions: { globals: globals.node } },
	{ files: ['web/*.cjs'], languageOptions: { sourceType: 'commonjs' } },
	// Run by IINA, not a browser: its API is the global iina, and it has setTimeout.
	{ files: ['iina-plugin/**'], languageOptions: { sourceType: 'script', globals: { iina: 'readonly', setTimeout: 'readonly' } } },
];
