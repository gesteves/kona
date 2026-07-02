// One-off Contentful migration: bumps every in-body Markdown heading up one level
// (### → ##, #### → ###) in article intro/body and page body. Part of the H1
// restructure: entry titles moved from <h2> to <h1> in the templates, so body
// subheadings — authored to sit under an <h2> title — shift up to keep the
// document outline intact. Deploy the template/CSS changes BEFORE running this.
//
// Run with `npm run migrate:headings` from contentful/ (dry run: `DRY_RUN=true npm run
// migrate:headings`), which loads contentful/.env (via `node --env-file`) so
// CONTENTFUL_SPACE and CONTENTFUL_MANAGEMENT_TOKEN are available. It prints the plan and
// prompts before applying. Undo with `npm run migrate:headings:revert`. Optional env vars:
//   ENTRY_ID=<sys.id>             restrict to a single entry (extra-safe trial)
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runHeadingShift } = require('./lib/shift-headings');

runHeadingShift(-1);
