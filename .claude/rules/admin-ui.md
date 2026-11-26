---
paths:
  - "api/app/views/admin/**"
  - "api/app/views/layouts/**"
  - "api/app/controllers/admin/**"
  - "api/app/presenters/**"
  - "api/app/helpers/**"
  - "api/app/javascript/**"
  - "api/config/locales/**"
  - "api/spec/requests/admin/**"
  - "api/spec/presenters/**"
  - "api/spec/support/translation_helpers.rb"
---

# The admin UI of `api/`

⚠️ **Each user-facing word of the admin is in `config/locales/en.yml`, below `en.admin.*`.**
A view uses the lazy key of its own path (`t(".title")` in `admin/spam/index.html.erb` reads
`en.admin.spam.index.title`), and a file below `app/views/layouts/` uses the full key, because it
renders from more than one page. A presenter, a controller, and a helper use the full key, and a
presenter calls `I18n.t` and not the bare `t`. **Write no user-facing word in an ERB file, in a Ruby
method, or in a JS file.**

- ⚠️ **This is for ONE place for the copy, and not for a second language.** A spec asserts
  `I18n.t("admin.…")` and never the words, thus a change to a word breaks no spec. That is the
  purpose. `spec/support/translation_helpers.rb` has `t_before`, for a message where an
  interpolated value — a date, a count — is the thing that the spec must prove.
- ⚠️ **Only the WORDS move.** An icon id, a path, a CSS class, a `data-` hook, a DOM id, and a Web
  Awesome `variant` stay in the code. `ConnectedAppPresenter#status_variant` stays beside
  `#status_label`, which left.
- ⚠️ **A DOM id must never come from a translated word.** The caption of a nav group takes its id
  from the `:key` of that group, and `aria-labelledby` points at it. An id from the label would
  move when a person changes a word.
- ⚠️ **Each key is a COMPLETE sentence.** Do not join one from a label and a fragment. Where a part
  is optional — a date, the "with the Bluesky handles" clause — there are **two keys** and the code
  selects one. `admin.social.errors.*` has a `single` form and a `numbered` form for that reason.
- ⚠️ **The widget views and the widget presenters are NOT part of this rule.** `WeatherSummaryPresenter`,
  `WhoopPresenter`, `EventWeatherPresenter`, and `UpcomingRacesPresenter` render public-site copy,
  which is part of the markup contract with `web/` and which the edge caches. Leave it in the code.
- **The words that a Stimulus controller renders come from the same file.** JavaScript cannot read
  `en.yml`, thus `AdminHelper#admin_i18n_data(scope, **nested)` writes the subtree into a
  `data-admin-i18n` attribute and `app/javascript/lib/i18n.js` reads it, does the `one`/`other`
  choice, and puts each `%{name}` value in.

**The stack: Turbo, Stimulus, and Web Awesome, and the server renders each page.** There is no SPA
framework and no separate front-end app, on purpose, and not because the plans are small: a maps UI,
a daily dashboard, and, later, a replacement for Contentful all belong here. Web Awesome already has
the admin components that those need, and one set of components across `web/` and `api/` is what
keeps the design system as one. When one screen truly needs state in the browser, add it as an
**island**: install the npm package, import it in `app/javascript/admin.js`, and start it from the
`connect()` of a Stimulus controller. The pipeline accepts that with no change.

**The styles are Sass**, with one BEM block in each partial below `app/javascript/styles/`, and
`admin.scss` imports them.

- ⚠️ **Do not use `<wa-icon>`.** It finds each icon through a base path or a Font Awesome kit code,
  and neither one is in this configuration. The npm package has no icon file, thus each icon is
  empty and it gives no message. Use `icon_svg(family, style, id)`, and **always with `raw`**: it
  returns a plain String, and without `raw` ERB escapes the markup and the page shows it as text.
  For an icon in a slot of a component (`start` or `end` on `<wa-button>`, and `icon` on
  `<wa-callout>`), use `slotted_icon_svg(family, style, id, slot:)`, which returns a safe buffer and
  needs no `raw`.
- ⚠️ **ARIA on a `wa-*` host does not reach the element in its shadow root.** `<wa-button>` renders
  its own `<button>` or `<a>`, and it sends `href`, `target`, `rel`, and `type` to that element but
  no ARIA. `icon_svg` also marks each SVG `aria-hidden`. Thus an `aria-label` or an `aria-current`
  on the host does nothing for a screen reader. Put the name or the state in the **content of the
  slot**, in a `wa-visually-hidden` span. The button in the header and the current item of the nav
  both do that. Turbo is different: it *does* go into a shadow root and out of it. It finds the
  anchor in a `wa-button` through the composed path of the click, and it then finds
  `data-turbo="false"` on the host. Thus a `<wa-button href>` navigates with Drive, as a plain link
  does.
- ⚠️ **A same-origin URL that redirects to a different origin needs `data-turbo="false"`.** Turbo
  Drive cannot follow that redirect. It fails with no message, and the click appears to do nothing.
  Today that is the Google sign-in form, the Mastodon instance form, and each Connect button of
  Connected apps.

**Use a Web Awesome component in place of a native element wherever one exists.** Use its layout
utilities (`wa-stack`, `wa-cluster`, `wa-grid`, `wa-gap-*`, and `wa-visually-hidden`) and its design
tokens (`--wa-space-*`, `--wa-color-*`, and `--wa-form-control-*`) in place of CSS that a person
writes. In practice that means **no** `button_to`, which writes a native `<button>`. Use `form_with`
around a `<wa-button type="submit">`. The button of Web Awesome is part of its form
(`formAssociated = true`), thus it submits that form as a native button does, and this includes the
CSRF token and `_method`. A plain `<button` in the server HTML means that one came back into the
code, and the admin request specs check that there is none.

Use Sass here for what is truly ours: the layout of one page, the brand colors, and a border that
the component does not draw. A rule that repeats the appearance of a component — its corner radius,
its hover color, its focus ring, or the height of a control — means that a person did not use the
API of that component. Use `appearance`, `variant`, or `size` first, then its CSS custom properties,
then `::part()`, and write your own rule last. The same applies to the markup: when a `wa-*` element
appears to have no method for something, read its documentation before you make your own code. More
than one difficult part here is documented behavior: the navigation slot of `<wa-page>`, the form
association, and `::part(base)`.

⚠️ **The package has its own documentation. Read it, and do not use an API from memory.** That
documentation is the source of the examples of the vendor, and its version is the version that you
installed:

- The skills of the vendor are on the disk at
  `node_modules/@web.awesome.me/webawesome-pro/dist/skills/`. There is one
  `webawesome/references/components/<name>.md` for each component, with its attributes, its slots,
  its parts, and its events. `webawesome/references/utilities/` and `tokens/` list the utilities
  and the tokens, and `webawesome-design/` covers the layout and the theme.
- When neither one has the answer, read the source and the styles of the component
  (`dist/components/<name>/` and `dist/chunks/*.js`). That is the only place with the shadow-DOM
  behavior above.

**Each admin page uses the same three parts.** Keep a new page the same:

- `<main>` is a `wa-stack wa-gap-xl`. Thus a page sets no margin between its blocks.
- `layouts/_page_header` makes the tab title, the back link, the `<h1>`, and the lead text.
- A list of items is an `admin-card-list plain-list wa-grid wa-gap-m` of `admin-card` cards. Refer to
  `_admin-card.scss`.

A form is a `wa-stack wa-gap-l`, and its buttons go in a `wa-cluster wa-gap-s` at its end. Each
button and each callout has an icon. A delete button on a card is `neutral`, and red is for the
confirm button in its dialog only, because the brand color is red.

**The messages.** ⚠️ **Each message that an action gives is a TOAST, and there is no flash callout.**

⚠️ **A `<wa-callout>` that stays on a page is a different thing, and it is correct.** An empty state
(Spam, Course maps), a warning about the configuration (Location, Course maps), and the error of one
card or one row (Connected apps, a failed track) are all true at each load of that page. A toast goes
away after some seconds and never comes back, thus **do not change one of those into a toast**.

## The admin specs

⚠️ **An admin spec asserts `I18n.t("admin.…")`, and never the words.** Each user-facing word of the
admin is in `config/locales/en.yml`, thus a change to the copy must break no spec.

- A literal stays only where that literal is the thing that the spec proves: a path, a piece of
  markup, `<button`, a secret that must be absent, and the escaped `<script>` payload of the spam
  page.
- ⚠️ **A body assertion escapes the translation** (`ERB::Util.html_escape(I18n.t(…))`), because ERB
  escaped the apostrophe of "didn't". A `flash` assertion compares the raw string.
- `t_before(key, :placeholder)` in `spec/support/translation_helpers.rb` gives the words before an
  interpolation. Use it where the value — a date, a count — is behaviour that the spec must prove
  and the words around it are copy.
- ⚠️ **Never assert that a translation equals its own key.** Such a spec proves nothing and it puts
  the copy back in two files.
