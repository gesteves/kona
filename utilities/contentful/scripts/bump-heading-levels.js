// A Contentful migration that runs one time: it moves each Markdown heading in a body up one level.
// Thus a subheading that a person wrote below an <h2> title keeps the correct document outline, now
// that each title is an <h1>. ⚠️ Deploy the template changes and the CSS changes before you run
// this.
//
// To run it: `npm run migrate:headings` from contentful/. To go back: `:revert`. The optional env
// vars:
//   DRY_RUN=true                  Show the changes of each entry and write nothing.
//   ENTRY_ID=<sys.id>             Use one entry only.
//   CONTENTFUL_ENVIRONMENT=<env>  Use an environment that is not master. The default is master.
const { runHeadingShift } = require('./lib/shift-headings');

runHeadingShift(-1);
