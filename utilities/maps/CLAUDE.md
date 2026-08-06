# utilities/maps — static map generation

A standalone Ruby/Rake utility that turns GPX tracks into static PNG map images, used as cover
images for race reports. Run locally, never deployed; nothing in `web/` or `api/` requires it, and
the PNGs are uploaded to Contentful by hand.

⚠️ **Keep it self-contained.** It has its own `Gemfile`, `Rakefile`, `.env`, and spec suite — don't
reach into `../../web` for anything, or the deploy isolation described in the root
[`CLAUDE.md`](../../CLAUDE.md) is gone. That file also has the comment-style conventions.

## Commands

Run everything from this directory.

```bash
bundle exec rake maps:generate   # render every GPX in data/gpx/ to data/images/
bundle exec rake maps:help       # full option reference (prints the env-var flags)
bundle exec rspec
```

`.github/workflows/utilities.yml` runs `rspec` on pushes and PRs touching `utilities/maps/**`.
It's checks-only — there's nothing to deploy.

## Layout

- `lib/static_map.rb` — `StaticMap`: parses the GPX, computes the bounding box, builds the Mapbox
  Static API URL, downloads the PNG.
- `lib/mapbox_tileset.rb` — `MapboxTileset`: uploads a track to the Mapbox Tiling Service as a
  private vector tileset (source → recipe → publish → poll), and `find`s an existing one.
- `lib/tasks/maps.rake` — the `maps:generate` / `maps:help` tasks. `:environment` comes from
  `dotenv/tasks`, which is what loads this directory's `.env`.
- `data/gpx/` (inputs) and `data/images/` (outputs) — both **gitignored**: working files, not
  source. Referenced as `StaticMap::GPX_FOLDER` / `IMAGES_FOLDER`.

## Things worth knowing

- **Tilesets are reused, not re-uploaded.** The id comes from the activity title (a 23-char slug
  plus an MD5 prefix of the full title, since Mapbox caps ids at 32 chars and long race names would
  otherwise collide). `ensure_tileset!` reuses an existing one, so iterating on padding, height, or
  margins costs one Static API request rather than a re-upload. `FORCE_UPLOAD` overrides this; use
  it when the GPX itself changed. ⚠️ The id hashes the **title**, so renaming a track mints a fresh
  tileset and re-uploads.
- **The source-layer name is pinned** to `MapboxTileset::LAYER_NAME` by the recipe, rather than
  derived from a filename. The `SOURCE_LAYER` env var exists only for the legacy `TILESET_ID`
  override path.
- **Mapbox credentials resolve lazily**, in `render_token`, so merely requiring the classes never
  demands a token — the Rakefile loads all of `lib/` at boot, including for `maps:help`. Keep it
  that way.
- **`PADDING` and `MIN_KM` are both CSS-style shorthand** (1–4 comma-separated values →
  top/right/bottom/left), parsed by the same `parse_box_shorthand`. `PADDING` is pixels inside the
  image; `MIN_KM` is kilometers of extra map around the track, converted to degrees with a
  cosine-of-latitude correction on longitude.
- **The specs construct instances with `allocate`**, bypassing the initializer (which wants a real
  GPX file on disk) and setting instance variables directly, so the geometry and URL-building
  methods can be exercised in isolation. `static_map_spec.rb` also pins the Mapbox env vars
  *before* requiring the class, because `MAPBOX_STYLE_URL` is read into a constant at load time.
