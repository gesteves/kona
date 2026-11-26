---
paths:
  - "web/source/**/*.erb"
  - "web/lib/helpers/{article,markup,site}_helpers.rb"
  - "web/spec/lib/helpers/{markup,site}_helpers_spec.rb"
  - "api/app/views/widgets/articles/**"
  - "api/app/helpers/{articles,plausible}_helper.rb"
  - "api/spec/contracts/article_click_contract_spec.rb"
  - "api/spec/helpers/plausible_helper_spec.rb"
  - "api/spec/requests/widgets/articles_trending_spec.rb"
---

# The analytics of a card click

Each link into an article carries the Plausible class names of one custom event, **`Article
Click`**, with a `section` property that names the module that holds the link. Thus the dashboard
answers "where does a reader enter an article from, inside the site". The tracking script also adds
a `url` property with the destination, and the `event:page` dimension of Plausible is the page that
the reader clicked on. Thus neither one needs a property.

**The heading of the section IS the value of `section`, word for word**, and the partial reads it
from the same `title` local that it renders. Thus the dashboard reads as the page reads.

⚠️ **A new heading is a new line in the dashboard, and that is the purpose.** The old line stops and
the new one starts on the day of the deploy, thus you can compare the two and see what the new words
did. Nothing joins them again, thus a heading that you change and then change back gives three
lines. Change a heading when you want that measurement.

Three values are overrides, because their heading cannot be the value:

| `section` | Module |
|---|---|
| `Blog List` | The blog index and each tag archive. ⚠️ Those pages have **no** section heading: the `<h1>` is the name of the page, and for a tag archive that is the name of the tag. Thus the heading would make one value for each tag, and `event:page` already gives you that. |
| `Recent Articles (404)` | The 404 page. ⚠️ Its heading is the same as the one on the home page. The plain heading would merge the two, and `event:page` cannot separate them: a 404 is served at whatever URL the reader asked for. |
| `Article Body` | A link to an article in the intro or the body of an article page or of the page of a Short, because the text has no heading. Pages and the cards of a list do not get it. |

⚠️ **The classes go on each `<a>`, and never on the card.** The tracking script walks **four nodes
up** from the click at the most, and it looks for the anchor and the tagged element together. From
the "Continue reading" link and from the date permalink, the `<article>` is outside that range. Such
a link then sends nothing, and it gives no message.

⚠️ The trending fragment is at the edge for an hour. Thus a change to these classes needs the manual
`widgets` tag purge of [`docs/cloudflare.md`](../../docs/cloudflare.md), or the cards keep the old
markup until that TTL ends.
