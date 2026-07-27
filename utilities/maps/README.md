# Static map generation

Renders GPX tracks as static PNG map images, for use as cover images on race reports.
Each track is uploaded to [Mapbox](https://www.mapbox.com/) as a private vector tileset
(via the [Mapbox Tiling Service](https://docs.mapbox.com/api/maps/mapbox-tiling-service/)),
then rendered with the
[Static Images API](https://docs.mapbox.com/api/maps/static-images/) against the track's
bounding box.

This is a **local-only utility** — it's never deployed, and neither `web/` nor `api/` depends
on it. The images it produces are uploaded to Contentful by hand. It lives in `utilities/`
so editing it never triggers a site build, deploy, or edge-cache purge (the "Web" workflow is
path-filtered on `web/**`).

## Setup (once)

Requirements: Ruby (see `.ruby-version`).

```bash
cd utilities/maps
bundle install
cp .env.example .env   # fill in the Mapbox credentials
```

A Mapbox account is needed, with:

- `MAPBOX_ACCESS_TOKEN` — public token used to render the static image.
- `MAPBOX_USERNAME` — your Mapbox account username, required for the upload.
- `MAPBOX_SECRET_TOKEN` — a secret token with the `tilesets:write` and `tilesets:read`
  scopes. Required for the upload, and preferred for rendering too, since it can read the
  private tilesets it creates.

## Usage

Drop `.gpx` files into `data/gpx/`, then:

```bash
bundle exec rake maps:generate       # render every GPX file in data/gpx/
bundle exec rake maps:help           # full option reference
bundle exec rspec                    # tests
```

Rendered PNGs land in `data/images/`, named after the activity title parsed out of the GPX.
Both directories are gitignored — they're working files, not source.

Re-running is cheap: a track whose tileset already exists is reused rather than re-uploaded,
so tweaking the render options below costs one Static API request. Pass `FORCE_UPLOAD` when
the GPX itself changed.

| Option | Effect |
| --- | --- |
| `PADDING=<value>` | Padding around the track in pixels; CSS-style 1–4 value shorthand (default: 50). |
| `MIN_KM=<value>` | Kilometers of map to add around the track; same shorthand, in km (default: 0). |
| `HEIGHT=<value>` | Override the image height in px (default: derived from the track's aspect ratio). |
| `REVERSE_MARKERS` | Swap the start/finish markers. |
| `DNF` | Mark the activity as a DNF (changes the finish marker's icon). |
| `FORCE_UPLOAD` | Re-upload the GPX even if its tileset already exists. |
| `TILESET_ID=<id>` | Skip the upload and render an existing tileset (single GPX file only). |
| `SOURCE_LAYER=<name>` | Source-layer to read when using `TILESET_ID` (default: `tracks`). |
| `MAPBOX_STYLE_URL=<url>` | Map style (default: `mapbox://styles/mapbox/outdoors-v12`). |
