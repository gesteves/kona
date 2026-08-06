// One-off Contentful migration: bumps every in-body Markdown heading up one level, so body
// subheadings authored under an <h2> title keep the document outline intact now that titles
// are <h1>. ⚠️ Deploy the template and CSS changes before running this.
//
// Run: `npm run migrate:headings` from contentful/; undo with `:revert`. Optional env vars:
//   DRY_RUN=true                  print per-entry diffs, write nothing
//   ENTRY_ID=<sys.id>             restrict to a single entry
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runHeadingShift } = require('./lib/shift-headings');

runHeadingShift(-1);
