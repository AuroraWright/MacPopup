// The lines the host notes for Anki Audio and Screenshot (native 'line', no test window), and which share an id, with
// the text box's duplicate settings off (plain) and on (merge: "skip repeats", "combine growing lines"). Plain: a sent
// line is a new line however much it looks like the one before, except a sent line with the text of the OCR line before
// it, which takes its place (replacesOCR). Merge: a repeat (……, ……) and a line growing from the one before (今日は,
// 今日はいい天気ですね。) are that line again, and so is the sent line after the one that replaced the OCR line;
// ありがとうございます/ました and はい after a line starting with it stay apart.
// settings: {"ocrMode": false, "floatingWindowOCR": false, "clipboardMonitor": false, "ankiEnabled": true, "preventLastDuplicate": 0, "preventGlobalDuplicate": false, "mergeEqualLineStarts": false}
// timeout: 60

test('overlay', async () => {
	const lines = [
		['a', 'はい、そうですね。今日は晴れています。'], ['b', 'はい'], ['c', 'ありがとうございます'], ['d', 'ありがとうございました'],
		['e', '……'], ['f', '……'], ['g', '今日は'], ['h', '今日はいい天気ですね。'],
		['i', '明日も晴れるといいね、まだ誰も知らない', true], ['j', '明日も晴れるといいね、まだ誰も知らない'], ['k', '明日も晴れるといいね、まだ誰も知らない'],
	];
	// Each line's name, with those sharing an id joined (a-b-c…: all apart).
	const run = async (name) => {
		const ids = {}, replaces = [];
		for (const [key, text, ocr] of lines) {
			const result = await native('line', ocr ? { text, ocr: true, rows: [text], breaks: [] } : { text });
			ids[key] = result?.id;
			if (result?.replacesOCR) replaces.push(key);
		}
		log(`${name}: ids ${JSON.stringify(ids)}`);
		const groups = [];
		for (const [key] of lines) {
			const group = groups.find((g) => ids[g[0]] !== undefined && ids[g[0]] === ids[key]);
			if (group) group.push(key); else groups.push([key]);
		}
		return { groups: groups.map((g) => g.join('=')), replaces };
	};
	await wait(1000);
	equal(await run('plain'), { groups: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i=j', 'k'], replaces: ['j'] }, 'plain: the lines (= sharing an id), and which replaced an OCR line');
	await native('setSettings', { json: JSON.stringify({ ...JSON.parse(await native('getSettings')), preventLastDuplicate: 1, mergeEqualLineStarts: true }) });
	await wait(500);
	equal(await run('merge'), { groups: ['a', 'b', 'c', 'd', 'e=f', 'g=h', 'i=j=k'], replaces: ['j'] }, 'merge: the lines (= sharing an id), and which replaced an OCR line');
});
