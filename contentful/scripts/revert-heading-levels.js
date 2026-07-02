// Inverse of bump-heading-levels.js: pushes every in-body Markdown heading down one
// level (## → ###, ### → ####). Rollback only — run with `npm run migrate:headings:revert`.
//
// Exact inverse for this site's content: no level-1 (`#`) or level-6 (`######`)
// headings exist, so neither direction ever hits the 1..6 clamp and a bump + revert
// round-trip is byte-identical. Same env vars as bump-heading-levels.js.
const { runHeadingShift } = require('./lib/shift-headings');

runHeadingShift(1);
