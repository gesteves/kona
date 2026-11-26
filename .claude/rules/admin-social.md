---
paths:
  - "api/app/**/*social*"
  - "api/app/**/*mention*"
  - "api/app/views/admin/social/**"
  - "api/app/services/social/{bluesky,mastodon,threads,open_graph}.rb"
  - "api/app/jobs/*_post_job.rb"
  - "api/spec/**/*social*"
  - "api/spec/**/*mention*"
  - "api/spec/jobs/*_post_job_spec.rb"
---

# The Social media page of the admin

**Social media** (`/social`) drafts a post, or a **thread** of them, for Bluesky, Mastodon, and
Threads, now or at a date and a time.

- **The link is a plain `wa-input type="url"`, and there is NO list of the entries.** The owner
  pastes a link. ⚠️ **Do not add a picker of the articles back.** The card of a post comes from the
  `og:` tags of whatever page the link names, thus a link to another site needs no more code, and a
  list would cover this one site only.
- ⚠️ **The picture is a proxy of ours, and never the `og:image` itself**, because `img-src` is
  `:self`. `GET /social/preview/image` sends it, exactly as the Course maps page proxies a Mapbox
  render.
- ⚠️ **The parameter of that proxy is the URL of the PAGE, and not of the picture.** Thus a caller
  cannot name any URL for this app to get: the picture is always the one that the `og:` tags of
  that page name.
- ⚠️ **Do not add a Bluesky threadgate or postgate control.** The owner read those options and
  refused them. This page has no control for one network alone.
- ⚠️ **The danger of a mention is not a mention that does nothing, it is a mention that tags a
  STRANGER.** `@tony.bsky.social` is correct at Bluesky, and Threads reads `@tony` in it and tags
  whoever holds that name. Nothing reports that.
- ⚠️ **The map of the mentions is part of the DRAFT, and nothing stores it.** It goes out with the
  form and it is gone after the post. There is no directory, no Redis key, and no admin page: a
  handle that a store holds goes out of date, and a name is needed for one draft only.
- ⚠️ **A thread that fails part of the way through leaves the posts above it published**, on that
  network only. This is accepted: the alternative is to delete posts that are already public, and a
  reader may have replied to one. Each other network has its own chain and is unaffected.
