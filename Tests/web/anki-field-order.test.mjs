// The note type's first field (lib/anki-connect.js, ankiFirstFieldName): modelFieldNames[0], not the card format's first
// key. Chromium's native messaging sorts object keys, so DefinitionPicture can come before Expression.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ankiFirstFieldName } from '../../web/src/lib/anki-connect.js';

// As Chromium hands a Kiku-style note type's card format to MacPopup.
const chromiumOrder = {
	DefinitionPicture: { value: '' },
	Expression: { value: '{expression}' },
	ExpressionAudio: { value: '{audio}' },
	Sentence: { value: '{sentence}' },
};

const ankiOrder = ['Expression', 'ExpressionFurigana', 'ExpressionReading', 'ExpressionAudio', 'DefinitionPicture', 'Sentence'];

test('the first field is Anki\'s, not the alphabetically first key', () => {
	assert.equal(Object.keys(chromiumOrder)[0], 'DefinitionPicture');
	assert.equal(ankiFirstFieldName(chromiumOrder, ankiOrder), 'Expression');
});

test('a first field the card format doesn\'t fill isn\'t replaced by another key', () => {
	assert.equal(ankiFirstFieldName(chromiumOrder, ['NotOnTheCard', 'Expression']), '');
	assert.equal(ankiFirstFieldName(chromiumOrder, []), '');
	assert.equal(ankiFirstFieldName(chromiumOrder, undefined), '');
	assert.equal(ankiFirstFieldName(undefined, ankiOrder), '');
});

test('an empty template on the first field still names that field', () => {
	const fields = { Expression: { value: '' }, Sentence: { value: '{sentence}' } };
	assert.equal(ankiFirstFieldName(fields, ['Expression', 'Sentence']), 'Expression');
});
