// Builds the iOS app's reading page (src/viewer, with lib/ocr-layer.js) and its list of Yomitan's languages into
// ../build/viewer, which ios/'s build copies into the app. Separate from build.mjs, which empties build/web.
import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';
import { languageSummaries } from './src/lib/languages.js';

const root = dirname(fileURLToPath(import.meta.url));
const source = join(root, 'src', 'viewer');
const out = join(root, '..', 'build', 'viewer');

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await esbuild.build({
	entryPoints: [join(source, 'viewer.js')],
	outdir: out,
	bundle: true,
	format: 'esm',
	target: 'safari18',
	logLevel: 'warning',
});

for (const file of ['viewer.html', 'viewer.css', 'sw.js']) {
	cpSync(join(source, file), join(out, file));
}

writeFileSync(join(out, 'languages.json'), JSON.stringify(languageSummaries.map(({ iso, name }) => ({ iso, name }))));
