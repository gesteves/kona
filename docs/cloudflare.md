# The Cloudflare zone

Read this file before you change the zone, and when you debug a 403, a 525, an image that does not
load, or an old page or widget from the cache. The root [`CLAUDE.md`](../CLAUDE.md) lists the
changes in the repo that need a change here.

⚠️ **No file in this repo configures the zone, and this file does not copy it.** Read the live
configuration with the `cf` CLI: `cf rulesets list --zone <zone>`, then
`cf rulesets entrypoint get <phase> --zone <zone>` for the rules of one phase. `cf bot-management
get`, `cf dns records list`, `cf managed-transforms list`, and `cf zones settings get <setting>` give
the rest. Read the zone before you decide that a problem is in the code. This file keeps only the
reason for each rule, and each link between a rule and the repo.

⚠️ Each rule names a host name that **a person typed and that nothing checked**. A host name
with an error saves correctly, shows as Active, and matches nothing, and it gives no message. Copy
each host name from the DNS records of the zone, then check that the Events counter of the rule is
more than zero.

- **The images** — Cloudflare Images serves each transformation from `<IMAGES_URL>/cdn-cgi/image/…`,
  and it gets the source from the R2 mirror. This needs **Transformations** on, with the mirror host
  in the list of the permitted sources.
  ⚠️ **Never add `*.ctfassets.net` to that list.** Its absence is necessary: it makes a bad or
  absent `IMAGE_HOST` fail with a message. With ctfassets in the list, the site looks correct and it
  comes directly from Contentful, and it uses the metered bandwidth that the mirror protects.
- **The source port** — a Request Header Transform Rule sets `X-Kona-Client-Port` on
  `POST /api/contact` of the site host, because `request.cf` has no port. The contact email and the
  Spam page show it. A report of a threat needs it: a carrier-grade NAT puts many subscribers behind
  one IPv4 address, and the IP, the port, and the time to the second select one. After an edit, send
  a test message and check its "Source port" line.

## The origin certificate

⚠️ **Cloudflare proxies each host, thus fly cannot renew its origin certificate by itself.** The A
and AAAA records of a host name Cloudflare, and not fly. Thus the usual check of fly fails, and
`fly certs show <host>` says "DNS records do not match the expected values" and keeps the status at
"Issuing…".

The certificate then expires, and the failure is silent and total. The fly edge sends **no
certificate**, Cloudflare answers **525 SSL handshake failed**, and **the fly log shows nothing**,
because no request completes the handshake. On the public API host this stops each widget and
`POST /api/icons`, thus the build of web fails with a 525 and names no cause.

**Each** host needs two more DNS records. Keep both **DNS only**, with no proxy:

```
CNAME _acme-challenge.<host>  →  <host>.<app id>.flydns.net.
TXT   _fly-ownership.<host>   →  app-<app id>
```

The CNAME lets Let's Encrypt do the DNS-01 challenge, and the TXT tells fly that we own a host that
a proxy fronts. `fly certs setup <host> -a kona-api` prints the two exact values, and
`fly certs check <host> -a kona-api` starts the check again after you add them.

⚠️ **Nothing in this repo watches that expiry, and there is no alarm.** Each host has its own
certificate and its own date. Read `fly certs list -a kona-api` first when a request to an origin
gives a 525.

## Cache Response Rules (tagging)

A deploy does **not** invalidate the edge by itself. Thus the invalidation is a separate step: a
rule gives each response the tag `Cache-Tag: site`, and `.github/workflows/web.yml` purges that tag
at each deploy.

The rule tags the full static build on the site host. On the api host, it tags the widget fragments
below `/widgets/articles/` and `/widgets/events/`: articles and events are Contentful content types,
and a Contentful publish starts a deploy. ⚠️ The cache holds a proxied widget under the **api** host
name, thus the rule must name that host.

⚠️ **Never change this into a match on the path only or on the host only, and never widen the second
part to `/widgets/`.** A purge removes the `stale-while-revalidate` and `stale-if-error` copies of a
fragment with the fresh copy, and those copies keep the widgets on the page through a fly failure.
With the tag on each widget, a Contentful publish during a failure would remove each widget on the
full site. The live-data widgets — `weather/current`, `activity-stats`, `whoop`, and
`plausible/pageviews/:id` — render nothing from Contentful and are in their own namespaces, and that
is what keeps them out of this rule.

⚠️ **The host of the image mirror is absent from both parts, on purpose.** Each of its objects is
immutable and the content gives its address, thus a purge can correct nothing. And with the tag,
each content publish would remove the full image cache.

A **second** rule gives each widget on the api host the tag `widgets`. It exists only to make a
manual `POST /zones/<id>/purge_cache` with `{"tags":["widgets"]}` one call and not approximately 60.

The two rules **stack**: a widget below `/widgets/articles/` or `/widgets/events/` gets both tags.
Each rule uses the **Add to existing tags** action, and that action makes them add. The order of the
two rules does not change the tags.

⚠️ **Keep the action of each rule at "Add to existing tags".** With "Override existing tags", the
`widgets` rule would remove `site` from each Contentful widget. The deploy purge would then miss
those widgets, and it would give no message.

Purge the `widgets` tag by hand only, and never in the deploy. Use it when the cached copy of a
widget is incorrect and time cannot correct it: after a change to a `cache_widget` TTL, because a
cached fragment keeps the `CDN-Cache-Control` that it had when it went into the cache, and after a
markup change that must arrive with the change to the web placeholder.

⚠️ A **Contentful widget below a NEW top-level namespace needs a change to this rule in the
dashboard**, and no file in the repo gives you that message. Without that change, the widget serves
old content for all time, and it gives no message.

⚠️ **Cloudflare Trace cannot show these rules.** Trace walks the request phases only, and it never
gets a response from an origin. To check a tag, purge it, then read `CF-Cache-Status` on the next
request.

(A `Cache-Tag` header from an origin also works. But the site host has no origin that writes a
header, and a header for the widgets would give one tag two sources in two apps. Thus one rule
covers the two hosts, and the warning above about a new namespace is the cost.)

## Cache Rules (edge TTL)

One rule gives the HTML of the site host an edge TTL of one year, and it ignores `Cache-Control`.
The purpose is to **keep the archive in the cache**. Most URLs here are old posts, and each PoP gets
few requests for them. Thus a short edge TTL removes them between two visits. The TTL is a maximum
and not a promise: each PoP removes an entry under LRU in each condition, thus this TTL only stops
being the limit. The reason for each exclusion:

- **`contains "."`** selects the HTML, because a page URL has no extension. Thus each asset with a
  fingerprint keeps the `immutable` policy that it already declares correctly.
- **`/widgets/`, `/api/`, and `/pa/`** — three of the four `run_worker_first` route families are on
  the site host and have no extension. A TTL of one year would keep each widget in the cache for all
  time, and a cached `/pa/*` would give incorrect analytics. **A new `run_worker_first` entry needs
  a matching exclusion here**, and no file in the repo gives you that message.

⚠️ **Never add a cache rule on the api host.** The `CDN-Cache-Control` of the origin gives the TTL of
each widget, and a cache rule would replace each of those values.

⚠️ **The deploy purge is the only thing between a TTL of one year and a page in the cache for one
year.** The rule ignores `Cache-Control`, thus a purge that matches nothing, with no message, leaves
that copy at the edge for almost all time. Count a purge failure in `web.yml` as an outage of the
page.

## Zone security rules

The zone is on Cloudflare **Pro**, thus the WAF **Managed Rules** and **Super Bot Fight Mode** apply
to the full zone, and this **includes the api host**. Almost all the traffic there is between two
machines, and it looks exactly like the traffic that SBFM stops.

⚠️ **The SBFM skip rule must exist *before* you set SBFM on.** Without it, each widget gives a 403
on the full site at the moment that SBFM starts.

Each Block rule stays above the skip rule, and the skip rule does not have "All remaining custom
rules" on.

**The scanner rule** is one long `or` over `lower(http.request.uri.path)`, and it matches by
*family*: the extensions, the tool prefixes, and the file names of secret material that a scanner
asks for.

⚠️ A scanner writes each **dot as a percent escape** (`/terraform/%2eenv%2estaging`), to go past a
match on the extension. Thus the rule also blocks a plain `contains "%2e"`. The **Normalize incoming
URLs** setting of the zone decides which of the two forms the rule sees, and Security Events shows
the raw path in both conditions. Thus you cannot know which form the rule saw. Each clause matches in
*both* forms, and you must remove neither one.

⚠️ Each prefix uses `starts_with`, and the rule applies to the full zone. `activate
:directory_indexes` puts each page at `/<slug>/`. Thus this rule would block a top-level page with
the slug `config`, `home`, `analytics`, or `deploy`, through its own prefix clause. Read
`data/pages.json` before you add a prefix, and read this note again if a new page ever gives a 403.
Each clause must also be false for each path that the api host serves, and for the shape of an R2
key (`{space}/{asset id}/{token}/{filename}`).

⚠️ **The admin UI is at the root of the admin host**, thus its pages use top-level paths. They have
the same problem from the other side: a new admin page with the name of one of those prefix
families would give a 403 in the full zone. Read this rule before you give a name to a new page.

**The original-image rule** knows "Cloudflare Images gets a source" from "a person types the URL",
through the `image-resizing` text that Cloudflare puts in `Via`.

⚠️ **Never change it into a block of the full host.** The fetch of the transformation also goes
through the rules, thus a block of the host gives a 403 for **each image on the site**. After an
edit, check **both** directions: a direct `curl` must give a 403, *and* a page must still show its
images.

⚠️ **It is a difficulty and not a boundary**, and it has two gaps. `Via` is an ordinary request
header (`curl -H 'Via: 1.1 image-resizing'` gives a 200), and the transformation endpoint on the
site host takes each width. Thus `/cdn-cgi/image/width=7728/<source>` gives a render at the full
resolution. Only a **smaller stored original** would limit the resolution that a person can get:
the mirror would hold `?w=2560` and not the original file.

**The skip rule** skips SBFM only, on the site host, on the public api host, and on the path `/up`
of each host. The managed rules run on each host. The rule names the api host and not a list of its
paths, because **the api app does that itself**: `API_HOST` in `api/config/routes.rb` draws each
route for the owner off the admin host only. Thus the public api host answers only `/up` and the
three machine namespaces.

⚠️ **The rule is a list of hosts, thus SBFM applies to each new host name by default.** A new host
that machines call, for example a second origin, needs an entry here, or SBFM blocks its callers
with no message.

The reason for the skip rule, for each host:

- **The site host** — SBFM blocks **each feed reader and each Open Graph scraper**, and its
  verified-bots setting can block Googlebot and Bingbot too. Those are exactly the traffic that a
  blog needs, and the unfurlers are the only readers of the OG cards. ⚠️ This host is not static
  only: `run_worker_first` takes `/widgets/*`, `/api/contact`, `/pa/*`, and the card paths, and
  `POST /api/contact` takes true text from a user. The honeypot, Turnstile, Akismet, the length
  limits, and the `contact/ip` throttle protect that endpoint. Do not use this skip rule as a reason
  to remove one of those.
- **The public api host** — `web/src/api-proxy.ts` sends an `authorization` header only, on purpose,
  because the cache entry must have the same bytes for each viewer. That gives a "this is a machine"
  fingerprint. `/api/` also covers the callers at build time. Strava POSTs its events to
  `/webhooks/` with no signature and no browser. ⚠️ **Meta also GETs each photo of a Threads post**
  from `/api/social-photos/*` on this host. A challenge there stops each Threads post with photos,
  and the only sign is an `ERROR` container in the job report.
- **The admin host** — SBFM stays on, because its traffic is a true browser that one person
  controls. The `/assets/*` files of the admin UI are also on this host, and the **static resource
  protection of SBFM is off**, which is what keeps them free of a challenge. ⚠️ Point each external
  uptime check at `/up`. The checks of fly reach the app on its internal host and never go through
  the zone.

⚠️ **A skip rule takes the signed `POST /webhooks/contentful` on the api host out of the managed
rules.** Contentful rich text can match a managed injection rule, and the HMAC check of the api
authenticates that request. Without the skip, a block stops the PDS sync and the site builds, and it
gives **no message**. Each other path below `/webhooks/` still goes through the managed rules. When a
webhook stops, read Security Events before you read the code.

⚠️ **The rate limiting rules are NOT in the skip list, on purpose.** Do not add them.

**The managed rules** — the **OWASP Core Ruleset** is **not** on, on purpose: it gives many false
results, and the main thing that it would catch here is the text of the contact form. If you ever set
it on, use PL1, the High threshold (60), and the Log action, and never a stricter value.

**Super Bot Fight Mode** — **static resource protection stays off**, because it would give a
challenge to the CSS, JavaScript, and font requests of the site.

**The rate limiting rules.** The Pro plan permits two:

- `/api/contact` — it stays on **Block**. ⚠️ Never use a challenge action: the native POST path with
  no JavaScript cannot answer a challenge, and that would break the path for a browser with no
  JavaScript.
- A limit on a crawler on the site host, then a Managed Challenge. ⚠️ Do not use a much lower number
  than approximately 200 requests each minute: Pagefind gets a group of index files for each search,
  and Turbo gets a page early when the pointer goes to a link. Thus one true reader is much above a
  simple rate.

**Polish and Mirage stay off**, because each image already goes through `/cdn-cgi/image/*`, which
selects the format and the quality.

**A zone rule blocks the bots, and no code does.** Do not add an edge function for it. If the
referral traffic or the analytics look incorrect, read the custom rules before you read the code.

## The image mirror

The api copies each Contentful image asset into an **R2 bucket**, which its own custom domain in the
zone serves, and that host name is the source of each transformation. `AssetMirror` and
`Contentful#rewrite_image_urls` give the contract: the key of each object is the Contentful path,
with no change.

⚠️ **A difference between the two sides makes each image on the site 404, and nothing reports it.**
Such a difference is the wrong bucket, the wrong custom domain, a key shape that a person "improved",
or an `IMAGE_HOST` with a value before the backfill was complete. The order of the steps: the
bucket, the custom domain, and the mirror host in the Transformations list; then
a deploy of the api with the `R2_*` secrets; then `rake assets:backfill` to its end; and *only then*
a value for `IMAGE_HOST` in the build environment of web. The images are broken between the last two
steps, thus keep that time short. And never correct it with ctfassets in the list.
