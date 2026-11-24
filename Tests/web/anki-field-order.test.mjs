// Anki's sort field is modelFieldNames[0], not the first key of the card format. Chromium's native
// messaging writes object keys alphabetically, so DefinitionPicture can sort ahead of Expression.
import assert from "node:assert/strict";
import { test } from "node:test";
import { ankiSortFieldName } from "../../web/src/lib/anki-connect.js";

// The order Chromium would hand MacPopup for a Kiku-style note type.
const chromiumOrder = {
  DefinitionPicture: { value: "" },
  Expression: { value: "{expression}" },
  ExpressionAudio: { value: "{audio}" },
  Sentence: { value: "{sentence}" },
};

const ankiOrder = [
  "Expression",
  "ExpressionFurigana",
  "ExpressionReading",
  "ExpressionAudio",
  "DefinitionPicture",
  "Sentence",
];

test("the sort field is Anki's first field, not the alphabetically first key", () => {
  assert.equal(Object.keys(chromiumOrder)[0], "DefinitionPicture");
  assert.equal(ankiSortFieldName(chromiumOrder, ankiOrder), "Expression");
});

test("a missing Anki first field is not replaced by another key", () => {
  assert.equal(
    ankiSortFieldName(chromiumOrder, ["NotOnTheCard", "Expression"]),
    "",
  );
  assert.equal(ankiSortFieldName(chromiumOrder, []), "");
  assert.equal(ankiSortFieldName(chromiumOrder, undefined), "");
  assert.equal(ankiSortFieldName(undefined, ankiOrder), "");
});

test("an empty template on the real first field still names that field", () => {
  const fields = {
    Expression: { value: "" },
    Sentence: { value: "{sentence}" },
  };
  assert.equal(
    ankiSortFieldName(fields, ["Expression", "Sentence"]),
    "Expression",
  );
});
