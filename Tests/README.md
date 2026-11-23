# Tests

Run them with `scripts/test.sh [unit|web|all]`. It prints PASS, or FAIL with the suites that failed, and exits with 1 on
a failure.

| Suite | Folder | Runs with | Needs | Time |
|---|---|---|---|---|
| unit | `Unit/` | `swift test` (Swift Testing) | nothing | ~45 s with the first debug build, then seconds |
| web | `web/` | `node --test Tests/web/` | Node | under a second |

## Unit (`Unit/`)

Plain logic in the Swift targets, one file per area. The test target imports the app and its modules with
`@testable import`, so internal types are reachable. Logic that sits in a SwiftUI view is moved out into a plain type
first (as `EditedLines` was out of Settings' `LinesEditor`).

## Web (`web/`)

The web code's modules (`web/src/lib`) that load without a page: most of them, except the ones importing Yomitan's
background code or Handlebars. Tests use `node:test` and `node:assert/strict`, with no packages to install.

## Writing a test

- Put it in the lowest suite that can catch the bug: unit or web before anything that launches the app.
- Name it after the behavior (`returnOnTheFifthLineIsRefused`), and check the result: no tests that only print.
- Keep fixtures small and in the test file, or next to it in a `Fixtures/` folder. Screenshots, recordings and audio
  from games or videos stay out of the repo (`test-corpus/`, local).
- Check a new test fails without the fix before relying on it.
