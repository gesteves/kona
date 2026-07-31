# utilities/aqi-map — PurpleAir AQI map, for screenshots

A fullscreen Mapbox map that shows what each PurpleAir sensor in view was reading at a given
past timestamp — PurpleAir's own map, but for a moment in the past. Pan/zoom to the frame you
want, hide the HUD, screenshot.

It's a **local screenshot tool**, not a service: it runs on `127.0.0.1`, isn't deployed, has no
tests and no CI, and nothing in `web/`, `api/`, or `utilities/maps/` depends on it. It was built
for one post's cover image and kept around for the next one — so treat the code as sketch
quality, and expect to touch it rather than configure it if the next map isn't an AQI map.

## Running it

```bash
cd utilities/aqi-map
cp .env.example .env   # then fill in the two keys
bundle install
bundle exec ruby app.rb
```

Then open, for example:

```
http://localhost:4567/?t=1753430400&center=43.6150,-116.2023&zoom=11
```

## URL parameters

| Param | Default | Meaning |
|---|---|---|
| `t` | now | The moment to render, as a unix timestamp in seconds. Also settable from the HUD |
| `center` | `43.6150,-116.2023` | Initial map center, `lat,lng` |
| `zoom` | `11` | Initial zoom |
| `style` | `MAPBOX_STYLE_URL`, else `mapbox://styles/mapbox/outdoors-v12` | Any Mapbox style URL |
| `hud` | `1` | `0` hides the HUD (or press `H` to toggle it) |

Sensors are loaded for the current viewport with the **"Load sensors in view"** button, not
automatically on pan — see below. They accumulate across loads, so you can build up coverage by
panning and loading a few times.

A load takes about a second per sensor, so **"Stop loading"** appears while one is running. It
cancels the crawl on the server as well as in the page, which is the point: reframe and load
again without waiting out a queue you've already moved away from, and without spending the API
points it would have cost. Starting a new load cancels a running one for the same reason.
Whatever had already arrived stays on the map.

**Click a badge to dim it**, click again to restore it. Dimmed badges drop to 35% opacity, and
hiding the HUD (`H`) hides them completely — so you can weed out the readings you don't want in
the shot and screenshot what's left.

## Picking a moment

The HUD has a date/time picker plus `−1d / −1h / +1h / +1d` buttons for scrubbing around to find
the interesting moment (a smoke plume arriving, say). The picker works in **your browser's
timezone**, so the readout underneath shows the UTC equivalent and the raw unix value to keep
that unambiguous when the map is somewhere else.

Changing the time **clears the circles** — they were readings for a different moment — so you
press "Load sensors in view" again. The URL's `?t=` stays in sync, so reloading or copying the
URL returns to the same moment.

## Things worth knowing

- **The style matches `utilities/maps`** (`outdoors-v12`), so a screenshot from here has the same
  look and feel as the static GPX maps. It reads the same `MAPBOX_STYLE_URL` variable too, so a
  custom style set for those applies here as well. `?style=` overrides both for a one-off.

- **It's slow, unavoidably.** PurpleAir has no bulk history endpoint, and
  `/v1/sensors/:id/history` is rate-limited to **1 request/sec per key**. So it's one sequential
  request per sensor — roughly a second each. That's why results stream in over Server-Sent
  Events rather than arriving at once, why the load is a button press rather than firing on
  every `moveend`, and why the sensor count is capped at 150 per load.
- **Readings are cached in-process** for the life of the server, keyed by sensor and timestamp
  (past readings never change), so panning back over ground already covered is instant.
- **History calls cost API points**, billed per row returned. The window is deliberately narrow
  (±30 min at 10-minute averaging) to keep that down.
- **Sensor coordinates are present-day values.** The history endpoint returns `null` for
  latitude/longitude, and there is no historical `confidence` field at all, so both come from
  `/v1/sensors` as they are *today*. A sensor relocated since the timestamp is plotted where it
  sits now, and the quality gate (`confidence >= 50`) reflects current health, not health at the
  time.
- **`max_age=0` on sensor discovery is load-bearing.** That parameter defaults to 604800 (7
  days), which would silently drop every sensor that has gone offline since the timestamp.
- **A PurpleAir 200 isn't proof of success** — `DataInitializingError` and truncated history
  responses both return 200 with a top-level `error` field, so the body is checked, not just the
  status.
- **The AQI math is copied from `api/app/services/purple_air.rb`** (the EPA humidity correction
  and the PM2.5→AQI conversion). `utilities/` must not depend on `api/`, so it's duplicated
  deliberately — ⚠️ which means a fix to the EPA correction upstream will **not** reach this
  copy, and nothing will flag the drift. If a map here disagrees with the site's own AQI widget,
  suspect that first.
- The colors are the AirNow scale applied as a **gradient** rather than discrete bands, which is
  what PurpleAir's map does. The ramp is interpolated in JS (`colorFor`), so there's no color
  code on the Ruby side.
- **Each badge is one DOM element (`mapboxgl.Marker`), not a circle layer plus a symbol layer.**
  That's deliberate and worth not "simplifying" back: Mapbox layers are global, so with two
  layers *every* label draws above *every* circle — a number would visibly spill across a
  neighbouring badge stacked on top of its own circle. One element per sensor makes circle and
  number stack as a unit, ordered by `z-index` = AQI so the worst reading wins an overlap.
  (`.mapboxgl-marker` is `position: absolute` and GL JS never sets `zIndex` itself, so that
  ordering is safe.) The trade-off: badges are DOM, not canvas, so a `canvas.toDataURL()` export
  would omit them — screenshot the window instead.
- **Which also means the badges always draw over the basemap's labels, and can't be put under
  them.** A DOM marker is an HTML element positioned on top of the map canvas, so nothing the
  map draws can cover it. Putting them beneath labels needs them to *be* a layer — which means
  baking each badge into an icon image and giving up the crisp DOM text. That was tried and
  reverted; it looked worse, and the labels are the lesser problem.
- **Dimming and hiding each fight a different stylesheet, and both fixes are load-bearing.**
  ⚠️ The dim rule needs `!important`: GL JS writes `opacity` *inline* on every marker element as
  part of its fog/terrain occlusion fade (normally to `1`), and an inline style beats a class
  selector, so without it a clicked badge silently never dims. It leaves `display` alone — which
  is why hiding worked while dimming didn't. ⚠️ Hiding, conversely, must use
  `style.display = 'none'` and **not** the `hidden` attribute, because `.aqi` sets
  `display: flex` and an author rule beats the UA stylesheet's `[hidden] { display: none }`.
