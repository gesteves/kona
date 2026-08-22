// The opposite of bump-heading-levels.js: it moves each Markdown heading in a body down one level,
// thus ## becomes ### and ### becomes ####. Use it to go back only, with
// `npm run migrate:headings:revert`.
//
// It is the exact opposite for the content of this site: there is no level-1 heading (`#`) and no
// level-6 heading (`######`). Thus neither direction reaches the limits of 1 and 6, and the two
// scripts together give the same bytes as before. The env vars are the same as in
// bump-heading-levels.js.
const { runHeadingShift } = require('./lib/shift-headings');

runHeadingShift(1);
