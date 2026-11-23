// Game Pause with a Windows game in Parallels' Coherence mode: the pause shortcut (window.__macpopupPauseShortcut, what
// the global shortcut calls) stops the whole VM (Parallels' prl_vm_app processes, by the pause helper, which runs as
// root), and pressing it again continues it; nothing else is stopped (Parallels' own app and the game's Mac-side app
// included). The driver has the person open a Windows app in Coherence, saves its window as the OCR window (Game Pause
// pauses that window's app; OCR Mode stays off, so it's never captured), and logs the VM's process states.
// Needs a person at the Mac with Parallels running a Windows VM, and the pause helper allowed (Settings → Permissions):
// ask before running it, it pauses the user's VM for about 8 s. Don't click anything while it's paused (switching apps
// ends the pause).
// interactive
// mock: MOCK_RUN_FILES=1
// env: MACPOPUP_DEBUG_OCR=1
// setup: prlctl list -o status | grep -q running || { echo "no Parallels VM is running"; exit 1; }
// settings: {"ocrMode": false, "gamePause": true, "gamePauseShortcut": null, "gamepadScanButtons": [], "clipboardMonitor": false, "ankiEnabled": false, "sentenceAudioEnabled": false}
// driver: python3 -I "$REPO/Tests/Manual/parallels-pause-driver.py"
// timeout: 600

test('overlay', async () => {
	const game = JSON.parse((await driverSaid('game: ', 400000)).slice('game: '.length));
	const settings = JSON.parse(await native('getSettings'));
	await native('setSettings', { json: JSON.stringify({ ...settings, ocrWindow: game }) });
	log(`ocrWindow: ${JSON.stringify(game)}`);
	await driverSaid('watching', 30000);
	await wait(2000);

	log(`pausing ${Date.now()}`);
	window.__macpopupPauseShortcut();
	await until('the pause', async () => (await gamePauseNotes()).some((n) => /^game (not )?paused/.test(n)), 10000).catch(() => {});
	log(`paused ${Date.now()}`);
	await wait(8000);
	log(`resuming ${Date.now()}`);
	window.__macpopupPauseShortcut();
	await wait(4000);
	log(`notes: ${JSON.stringify(await gamePauseNotes())}`);
	const notes = await gamePauseNotes();
	expect(notes.some((n) => n.startsWith('game paused: ')), `Game Pause paused the game: ${JSON.stringify(notes)}`);
	expect(!notes.some((n) => n.startsWith('the pause helper')), 'the pause helper stopped every process asked for');
	log('done');
});
