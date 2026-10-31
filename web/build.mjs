// Builds the web assets into ../build/web (served by the app under macpopup://app/).
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));
const out = join(root, '..', 'build', 'web');
const yomitan = join(root, '..', 'vendor', 'yomitan', 'ext');

// Yomitan modules that need extension APIs or extra libraries, replaced by ones that work here.
const yomitanReplacements = {
	name: 'yomitan-replacements',
	setup(build) {
		build.onResolve({ filter: /\/background\/request-builder\.js$/ }, () => ({ path: join(root, 'src', 'lib', 'request-builder.js') }));
		build.onResolve({ filter: /\/dom\/simple-dom-parser\.js$/ }, () => ({ path: join(root, 'src', 'lib', 'simple-dom-parser.js') }));
	},
};

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await esbuild.build({
	entryPoints: ['overlay.js', 'popup.js'].map((file) => join(root, 'src', file)),
	outdir: out,
	bundle: true,
	format: 'esm',
	target: 'safari17',
	loader: { '.handlebars': 'text' },
	// Lets vendor/yomitan-handlebars find the handlebars package.
	nodePaths: [join(root, 'node_modules')],
	plugins: [yomitanReplacements],
	logLevel: 'warning',
});

// Run by the native Settings window in JavaScriptCore (SettingsSupport.swift).
await esbuild.build({
	entryPoints: [join(root, 'src', 'settings-support.js')],
	outdir: out,
	bundle: true,
	format: 'iife',
	globalName: 'MacPopupSettingsSupport',
	target: 'safari17',
	loader: { '.handlebars': 'text' },
	logLevel: 'warning',
});

execFileSync(
	join(root, 'node_modules', '.bin', 'tailwindcss'),
	['-c', join(root, 'tailwind.config.cjs'), '-i', join(root, 'src', 'app.css'), '-o', join(out, 'app.css'), '--minify'],
	{ cwd: root, stdio: ['ignore', 'ignore', 'inherit'] },
);

for (const file of ['overlay.html', 'popup.html', 'popup-extra.css']) {
	cpSync(join(root, 'src', file), join(out, file));
}

// Yomitan's popup assets, at the root-relative paths its CSS and templates expect.
cpSync(join(yomitan, 'css'), join(out, 'css'), { recursive: true });
cpSync(join(yomitan, 'images'), join(out, 'images'), { recursive: true });
cpSync(join(yomitan, 'templates-display.html'), join(out, 'templates-display.html'));
// Styles that Yomitan's Anki renderer inlines into glossaries and pitch accents.
mkdirSync(join(out, 'data'), { recursive: true });
for (const file of ['structured-content-style.json', 'pronunciation-style.json']) {
	cpSync(join(yomitan, 'data', file), join(out, 'data', file));
}
// The sounds played when no audio is found (Yomitan's audio fallback sound).
cpSync(join(yomitan, 'data', 'audio'), join(out, 'data', 'audio'), { recursive: true });
const strokeFont = join(root, '..', 'build', 'cache', 'kanji-stroke-orders.ttf');
if (existsSync(strokeFont)) {
	mkdirSync(join(out, 'data', 'fonts'), { recursive: true });
	cpSync(strokeFont, join(out, 'data', 'fonts', 'kanji-stroke-orders.ttf'));
}

console.log(`Web assets built in ${out}`);
