# A local page: a fullscreen Mapbox map of what each PurpleAir sensor was reading at a past
# timestamp, to be panned to a good frame and screenshotted for a post's cover image.
#
# ⚠️ Local-only and bound to 127.0.0.1 — it proxies a PurpleAir key with no auth of its own.
#
# The browser can't call PurpleAir directly: the key would be exposed, CORS isn't guaranteed,
# and the history endpoint is rate-limited to one request per second per key, which has to be
# sequenced somewhere. So this proxies it and streams results back as Server-Sent Events, and
# circles appear as they resolve rather than the page sitting blank for a minute.

require 'sinatra'
require 'httparty'
require 'json'
require 'dotenv/load'

set :bind, '127.0.0.1'
set :port, ENV.fetch('PORT', 4567)
enable :inline_templates

PURPLE_AIR_API_URL = 'https://api.purpleair.com/v1'

# Outdoor sensors only, and `confidence` is PurpleAir's own data-quality score — the same
# >= 50 gate api/app/services/purple_air.rb uses.
MIN_CONFIDENCE = 50

# History averaging interval, in minutes (PurpleAir allows 0/10/30/60/360/1440/…), and how far
# either side of the target timestamp to search. Passing both start_timestamp and
# end_timestamp keeps the row count — and so the API point cost — down.
AVERAGE_MINUTES = 10
WINDOW_SECONDS = 30 * 60

# The history endpoint's rate limit is 1 req/sec per key. A little headroom avoids
# RateLimitExceededError on a slow clock.
RATE_LIMIT_SLEEP = 1.1

# One request per sensor at ~1s each, so a zoomed-way-out view could otherwise kick off an
# hour of requests (and spend a lot of API points).
MAX_SENSORS = 150

HTTP_TIMEOUT = 30

# Readings never change once they're in the past, so a process-local cache makes panning back
# over ground already covered free rather than another minute of sequential requests.
# Keyed [sensor_index, timestamp]; a miss with no usable data is cached as :none.
READING_CACHE = {}
CACHE_MUTEX = Mutex.new

# Identifies the newest sensor crawl. `/sensors` takes the next number and checks it between
# sensors, so anything that bumps the counter makes an older loop notice it's stale and stop.
# Closing the EventSource isn't enough on its own: writes to a dropped connection don't fail
# promptly, so the loop would keep spending API points on a frame you've already left.
RUN_MUTEX = Mutex.new
RUN = { id: 0 }

def begin_run!
  RUN_MUTEX.synchronize { RUN[:id] += 1 }
end

def current_run
  RUN_MUTEX.synchronize { RUN[:id] }
end

# Cancels whatever crawl is running. Sent by the HUD's Stop button (as a beacon, so it still
# arrives if the page is navigating away).
post '/stop' do
  begin_run!
  status 204
end

get '/' do
  token = ENV['MAPBOX_ACCESS_TOKEN'].to_s
  halt 500, 'MAPBOX_ACCESS_TOKEN is not set. Copy .env.example to .env and fill it in.' if token.empty?

  lat, lng = parse_center(params['center'])

  erb :index, locals: {
    token: token,
    timestamp: parse_timestamp(params['t']),
    latitude: lat,
    longitude: lng,
    zoom: (params['zoom'] || 11).to_f,
    style: map_style(params['style']),
    hud: params['hud'] != '0'
  }
end

# Streams the sensors visible in the given bounds, one Server-Sent Event each, with their AQI
# at the given timestamp.
get '/sensors' do
  halt 500, 'PURPLEAIR_API_KEY is not set.' if ENV['PURPLEAIR_API_KEY'].to_s.empty?

  timestamp = parse_timestamp(params['t'])
  bounds = {
    nwlat: params['nwlat'].to_f,
    nwlng: params['nwlng'].to_f,
    selat: params['selat'].to_f,
    selng: params['selng'].to_f
  }

  content_type 'text/event-stream'
  headers 'Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no'

  # Claim this crawl. Starting a load implicitly cancels any earlier one still running.
  run = begin_run!

  stream do |out|
    begin
      found = sensors_in_bounds(bounds, timestamp)
      queued = found.first(MAX_SENSORS)
      out << sse(:meta, found: found.size, queued: queued.size, seconds: (queued.size * RATE_LIMIT_SLEEP).round)

      queued.each do |sensor|
        # Checked before each sensor's request, so Stop takes effect within one sensor.
        break unless current_run == run

        begin
          aqi = aqi_for(sensor, timestamp)
          next if aqi.nil?
          out << sse(:sensor, index: sensor[:index], lon: sensor[:lon], lat: sensor[:lat], aqi: aqi)
        rescue StandardError => e
          # One dead sensor shouldn't end the stream.
          out << sse(:warn, index: sensor[:index], message: e.message)
        end
      end

      out << sse(:done, {})
    rescue StandardError => e
      out << sse(:fatal, message: e.message)
    end
  end
end

# Sensors inside the bounds that plausibly had data at the target timestamp.
#
# `max_age: 0` is load-bearing: it defaults to 7 days, which would silently drop every sensor
# that has gone offline since a historical timestamp. Coordinates and confidence are the
# sensor's present-day values — history returns neither — so a relocated sensor is plotted
# where it sits today.
# @see https://api.purpleair.com/#api-sensors-get-sensors-data
def sensors_in_bounds(bounds, timestamp)
  body = purple_air_get('/sensors', {
    fields: 'sensor_index,latitude,longitude,confidence,date_created,last_seen',
    location_type: 0,
    max_age: 0
  }.merge(bounds))

  column = index_of(body['fields'])
  rows = body['data'] || []

  rows.filter_map do |row|
    lat = row[column['latitude']]
    lon = row[column['longitude']]
    next if lat.nil? || lon.nil?
    next if row[column['confidence']].to_i < MIN_CONFIDENCE
    next if row[column['date_created']].to_i > timestamp
    next if row[column['last_seen']].to_i < timestamp

    { index: row[column['sensor_index']], lat: lat, lon: lon }
  end
end

# The sensor's EPA-corrected AQI at the timestamp, or nil when it has no usable reading there.
def aqi_for(sensor, timestamp)
  key = [sensor[:index], timestamp]
  cached = CACHE_MUTEX.synchronize { READING_CACHE[key] }
  return cached == :none ? nil : cached if cached

  reading = reading_at(sensor[:index], timestamp)
  sleep RATE_LIMIT_SLEEP

  corrected = reading && apply_epa_correction(reading[:pm25], reading[:humidity])
  aqi = corrected&.positive? ? format_aqi(corrected) : nil
  aqi = nil unless aqi&.positive?

  CACHE_MUTEX.synchronize { READING_CACHE[key] = aqi || :none }
  aqi
end

# The history row nearest the target timestamp.
# @see https://api.purpleair.com/#api-sensors-get-sensor-history
def reading_at(sensor_index, timestamp)
  body = purple_air_get("/sensors/#{sensor_index}/history", {
    fields: 'pm2.5_atm,humidity',
    average: AVERAGE_MINUTES,
    start_timestamp: timestamp - WINDOW_SECONDS,
    end_timestamp: timestamp + WINDOW_SECONDS
  })

  rows = body['data'] || []
  return if rows.empty?

  column = index_of(body['fields'])
  time = column['time_stamp'] || 0
  row = rows.min_by { |r| (r[time].to_i - timestamp).abs }

  { pm25: row[column['pm2.5_atm']], humidity: row[column['humidity']] }
end

def purple_air_get(path, query)
  response = HTTParty.get(
    "#{PURPLE_AIR_API_URL}#{path}",
    query: query,
    headers: { 'X-API-Key' => ENV['PURPLEAIR_API_KEY'] },
    timeout: HTTP_TIMEOUT
  )

  body = begin
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    nil
  end

  # A 200 isn't proof of success: DataInitializingError responds 200, and a truncated response
  # carries a top-level `error` alongside partial data.
  raise "PurpleAir #{body['error']}: #{body['description'] || 'no description'}" if body.is_a?(Hash) && body['error']
  raise "PurpleAir returned status #{response.code}" unless response.success?
  raise 'PurpleAir returned an unparseable body' unless body.is_a?(Hash)

  body
end

# PurpleAir responses are columnar — a `fields` array naming the columns of each `data` row —
# and the column order is explicitly not stable, so always look positions up by name.
def index_of(fields)
  Array(fields).each_with_index.to_h
end

def sse(event, data)
  "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
end

def parse_timestamp(value)
  value.to_s.match?(/\A\d+\z/) ? value.to_i : Time.now.to_i
end

# Defaults to the style utilities/maps renders its static GPX maps with, and honors the same
# MAPBOX_STYLE_URL, so screenshots from here match those. `?style=` overrides for a one-off.
def map_style(param)
  [param, ENV['MAPBOX_STYLE_URL']].find { |v| !v.to_s.strip.empty? } ||
    'mapbox://styles/mapbox/outdoors-v12'
end

def parse_center(value)
  lat, lng = value.to_s.split(',').map { |v| Float(v, exception: false) }
  lat && lng ? [lat, lng] : [43.6150, -116.2023]
end

# --- AQI math -------------------------------------------------------------------------------
#
# Ported verbatim (minus ActiveSupport) from api/app/services/purple_air.rb. utilities/ must
# not depend on api/, so this is duplication by design — but it means a correction to the EPA
# formula upstream will not reach this copy, and nothing flags the drift. If a map here
# disagrees with the site's own AQI widget, check this against the api's version first.

# Applies the EPA humidity correction to raw PM2.5.
# @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
def apply_epa_correction(pm25, humidity)
  return if pm25.nil?
  return pm25 if humidity.nil?

  case pm25
  when 0...30
    0.524 * pm25 - 0.0862 * humidity + 5.75
  when 30...50
    # Transition band: blend the low and mid corrections by w = pm25/20 - 1.5 (0→1 across the band).
    w = pm25 / 20.0 - 1.5
    ((0.786 * w + 0.524 * (1 - w)) * pm25) - 0.0862 * humidity + 5.75
  when 50...210
    0.786 * pm25 - 0.0862 * humidity + 5.75
  when 210...260
    # Transition band: blend the mid and high corrections by w = pm25/50 - 4.2 (0→1 across the band).
    w = pm25 / 50.0 - 4.2
    ((0.69 * w + 0.786 * (1 - w)) * pm25) -
      0.0862 * humidity * (1 - w) +
      2.966 * w +
      5.75 * (1 - w) +
      8.84e-4 * pm25**2 * w
  else
    2.966 + 0.69 * pm25 + 8.841e-4 * pm25**2
  end
end

# Converts PM2.5 to an AQI value. (The api's version also returns a category and description;
# the map only needs the number, since the color comes from a Mapbox expression.)
# @see https://www.epa.gov/system/files/documents/2024-02/pm-naaqs-air-quality-index-fact-sheet.pdf
def format_aqi(pm25)
  return if pm25.nil?
  pm25 = pm25.round(1)

  case pm25
  when 0..9.0     then calculate_aqi(pm25, 0, 9.0, 0, 50)
  when 9.1..35.4  then calculate_aqi(pm25, 9.1, 35.4, 51, 100)
  when 35.5..55.4 then calculate_aqi(pm25, 35.5, 55.4, 101, 150)
  when 55.5..125.4 then calculate_aqi(pm25, 55.5, 125.4, 151, 200)
  when 125.5..225.4 then calculate_aqi(pm25, 125.5, 225.4, 201, 300)
  else calculate_aqi(pm25, 225.5, 500.0, 301, 500)
  end
end

def calculate_aqi(pm25, pm25_low, pm25_high, aqi_low, aqi_high)
  pm25 = pm25.round(1)
  if pm25 > 500
    (((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_high) + aqi_high).round
  else
    ((((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_low)) + aqi_low).round
  end
end

__END__

@@index
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>PurpleAir AQI &middot; <%= Time.at(timestamp).utc.strftime('%Y-%m-%d %H:%M UTC') %></title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link href="https://api.mapbox.com/mapbox-gl-js/v3.9.0/mapbox-gl.css" rel="stylesheet">
  <script src="https://api.mapbox.com/mapbox-gl-js/v3.9.0/mapbox-gl.js"></script>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; }
    #map { position: absolute; inset: 0; }
    #hud {
      position: absolute; top: 12px; left: 12px; z-index: 1;
      font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      background: rgba(255, 255, 255, .94); color: #111;
      border-radius: 8px; padding: 10px 12px;
      box-shadow: 0 1px 4px rgba(0, 0, 0, .25);
      max-width: 280px;
    }
    #hud[hidden] { display: none; }
    #hud label { display: block; font-weight: 600; margin-bottom: 4px; }
    #hud input { font: inherit; width: 100%; box-sizing: border-box; }
    #hud button { font: inherit; margin-top: 8px; width: 100%; padding: 5px; cursor: pointer; }
    #hud button[disabled] { cursor: default; opacity: .55; }
    #hud .nudge { display: flex; gap: 4px; }
    #hud .nudge button { flex: 1; margin-top: 6px; padding: 3px 0; }
    #utc { color: #666; font-size: 11px; margin: 6px 0; }
    #status { color: #555; }

    /* One element per sensor, so circle and number stack together as a unit. */
    .aqi {
      width: 36px; height: 36px; border-radius: 50%;
      display: flex; align-items: center; justify-content: center;
      font: 600 14px/1 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      border: 1px solid rgba(0, 0, 0, .15);
      user-select: none; cursor: pointer;
    }
    /* Clicked to "not part of the shot". Hidden outright once the HUD is.
       !important is load-bearing: GL JS writes `opacity` *inline* on every marker element as
       part of its fog/terrain occlusion fade (normally to 1), and an inline style beats a class
       selector — so without it the badge silently never dims. It leaves `display` alone, which
       is why hiding works and dimming didn't. Nothing here uses terrain, globe, or fog, so
       overriding that fade costs nothing. */
    .aqi.is-dim { opacity: .35 !important; }
  </style>
</head>
<body>
  <div id="map"></div>
  <div id="hud" <%= 'hidden' unless hud %>>
    <label for="when">Show readings at</label>
    <input type="datetime-local" id="when">
    <div class="nudge">
      <button data-shift="-86400" title="One day earlier">&minus;1d</button>
      <button data-shift="-3600" title="One hour earlier">&minus;1h</button>
      <button data-shift="3600" title="One hour later">+1h</button>
      <button data-shift="86400" title="One day later">+1d</button>
    </div>
    <div id="utc"></div>
    <div id="status">Loading&hellip;</div>
    <button id="load" disabled>Load sensors in view</button>
    <button id="stop" hidden>Stop loading</button>
  </div>

  <script>
    // The moment being rendered. Mutable: the HUD's picker changes it.
    let timestamp = <%= timestamp %>;

    // Whether the HUD (and, with it, the dimmed badges) is showing. Toggled by H.
    let chromeVisible = <%= hud.to_json %>;

    const hud = document.getElementById('hud');
    const status = document.getElementById('status');
    const loadButton = document.getElementById('load');
    const stopButton = document.getElementById('stop');
    const whenInput = document.getElementById('when');
    const utcHint = document.getElementById('utc');

    mapboxgl.accessToken = <%= token.to_json %>;
    const map = new mapboxgl.Map({
      container: 'map',
      style: <%= style.to_json %>,
      center: [<%= longitude %>, <%= latitude %>],
      zoom: <%= zoom %>
    });

    // Sensors accumulate across loads, keyed by index, so panning around builds up coverage
    // instead of replacing it.
    const markers = new Map();

    // Badges you've clicked to dim: "not part of the shot". They fade out, and disappear
    // entirely once the HUD is hidden, so the screenshot shows only the ones you kept.
    const dimmed = new Set();

    function clearMarkers() {
      markers.forEach((marker) => marker.remove());
      markers.clear();
      dimmed.clear();
    }

    function toggleDim(index) {
      if (dimmed.has(index)) dimmed.delete(index); else dimmed.add(index);
      applyBadgeState(index);
    }

    function applyBadgeState(index) {
      const marker = markers.get(index);
      if (!marker) return;

      const element = marker.getElement();
      const isDim = dimmed.has(index);
      element.classList.toggle('is-dim', isDim);
      // Not the `hidden` attribute: .aqi sets `display: flex`, and an author rule beats the UA
      // stylesheet's `[hidden] { display: none }`, so the badge would stay visible.
      element.style.display = isDim && !chromeVisible ? 'none' : '';
    }

    // The AirNow scale as a gradient rather than discrete bands, which is what PurpleAir's own
    // map does. This was a Mapbox `interpolate` expression until the badges became DOM
    // elements; same anchors, interpolated in sRGB.
    const RAMP = [
      [0, [0x00, 0xe4, 0x00]],
      [50, [0xff, 0xff, 0x00]],
      [100, [0xff, 0x7e, 0x00]],
      [150, [0xff, 0x00, 0x00]],
      [200, [0x8f, 0x3f, 0x97]],
      [300, [0x7e, 0x00, 0x23]]
    ];

    function colorFor(aqi) {
      if (aqi <= RAMP[0][0]) return `rgb(${RAMP[0][1]})`;
      for (let i = 1; i < RAMP.length; i++) {
        const [hi, hiRgb] = RAMP[i];
        const [lo, loRgb] = RAMP[i - 1];
        if (aqi > hi) continue;
        const t = (aqi - lo) / (hi - lo);
        return `rgb(${loRgb.map((c, j) => Math.round(c + t * (hiRgb[j] - c)))})`;
      }
      return `rgb(${RAMP[RAMP.length - 1][1]})`;
    }

    // Adds (or replaces) one sensor's badge.
    //
    // Each badge is a single DOM element rather than a circle layer plus a symbol layer: with
    // two Mapbox layers, *every* label draws above *every* circle, so a label would spill over
    // a neighbouring badge that sits on top of its own circle. z-index by AQI means the worst
    // reading wins an overlap, circle and number together.
    function addMarker(sensor) {
      markers.get(sensor.index)?.remove();

      const element = document.createElement('div');
      element.className = 'aqi';
      element.textContent = sensor.aqi;
      element.style.backgroundColor = colorFor(sensor.aqi);
      element.style.color = sensor.aqi > 150 ? '#ffffff' : '#000000';
      element.style.zIndex = Math.max(0, Math.round(sensor.aqi));
      element.title = `Sensor ${sensor.index} · AQI ${sensor.aqi}`;
      element.addEventListener('click', () => toggleDim(sensor.index));

      markers.set(sensor.index, new mapboxgl.Marker({ element })
        .setLngLat([sensor.lon, sensor.lat])
        .addTo(map));

      // A sensor re-delivered by a later load keeps whatever dim state you gave it.
      applyBadgeState(sensor.index);
    }

    // --- Time picker ---
    //
    // The <input type="datetime-local"> works in the *browser's* timezone, which is a good
    // default but easy to misread when the map is somewhere else — hence the UTC/unix readout
    // underneath it.

    const pad = (n) => String(n).padStart(2, '0');

    function syncTimeUi() {
      const d = new Date(timestamp * 1000);
      whenInput.value = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
                        `T${pad(d.getHours())}:${pad(d.getMinutes())}`;
      const utc = d.toISOString().slice(0, 16).replace('T', ' ');
      utcHint.textContent = `${utc} UTC · t=${timestamp}`;
      document.title = `PurpleAir AQI · ${utc} UTC`;

      // Keep ?t= in sync so a reload (or a copied URL) comes back to the same moment.
      const url = new URL(location.href);
      url.searchParams.set('t', timestamp);
      history.replaceState(null, '', url);
    }

    // Changing the moment invalidates every circle on the map — they're readings for a
    // different time — so clear them and wait for an explicit reload.
    function setTimestamp(next) {
      timestamp = next;
      stop();
      clearMarkers();
      syncTimeUi();
      status.textContent = 'Time changed — load sensors for this view.';
    }

    whenInput.addEventListener('change', () => {
      const parsed = Math.floor(new Date(whenInput.value).getTime() / 1000);
      // An empty or half-typed value parses to NaN; put the previous value back.
      if (!Number.isFinite(parsed)) return syncTimeUi();
      setTimestamp(parsed);
    });

    document.querySelectorAll('.nudge button').forEach((button) => {
      button.addEventListener('click', () => setTimestamp(timestamp + Number(button.dataset.shift)));
    });

    syncTimeUi();

    map.on('load', load);

    // Deliberately manual, not on every 'moveend': each pan would otherwise start a fresh
    // sequential crawl at ~1 sensor/second and spend API points while you're still hunting
    // for a frame.
    loadButton.addEventListener('click', load);
    stopButton.addEventListener('click', () => stop('Stopped. Reframe and load again.'));

    // The live stream, if one is running. Kept at this scope so stop() can reach it.
    let events = null;

    // Ends the in-flight load, on both sides. Closing the EventSource alone would only stop the
    // *page* listening — the server would keep crawling PurpleAir at a second a sensor, spending
    // API points on a frame you've already moved away from. POST /stop cancels it at the source.
    function stop(message) {
      if (!events) return;
      events.close();
      events = null;
      navigator.sendBeacon('/stop');
      stopButton.hidden = true;
      loadButton.disabled = false;
      if (message) status.textContent = message;
    }

    function load() {
      stop();
      loadButton.disabled = true;
      stopButton.hidden = false;
      status.textContent = 'Finding sensors…';

      const b = map.getBounds();
      const query = new URLSearchParams({
        t: timestamp,
        nwlat: b.getNorth(), nwlng: b.getWest(),
        selat: b.getSouth(), selng: b.getEast()
      });

      const stream = new EventSource('/sensors?' + query);
      events = stream;
      let expected = 0;
      let loaded = 0;

      const finish = (message) => {
        stream.close();
        if (events === stream) events = null;
        status.textContent = message;
        stopButton.hidden = true;
        loadButton.disabled = false;
      };

      stream.addEventListener('meta', (e) => {
        const meta = JSON.parse(e.data);
        expected = meta.queued;
        if (expected === 0) return finish('No sensors with data here at that time.');
        const capped = meta.found > meta.queued ? ` (of ${meta.found} found)` : '';
        status.textContent = `0 / ${expected}${capped} — about ${meta.seconds}s…`;
      });

      stream.addEventListener('sensor', (e) => {
        addMarker(JSON.parse(e.data));
        loaded += 1;
        status.textContent = `${loaded} / ${expected}…`;
      });

      stream.addEventListener('warn', (e) => console.warn('sensor', JSON.parse(e.data)));
      stream.addEventListener('done', () => finish(`${loaded} of ${expected} sensors shown.`));
      stream.addEventListener('fatal', (e) => finish('Error: ' + JSON.parse(e.data).message));
      stream.onerror = () => finish('Connection lost. Is the server still running?');
    }

    // Hiding the HUD is the last step before a screenshot, so it takes the dimmed badges with
    // it: what's left on screen is exactly what you kept.
    function applyChrome() {
      hud.hidden = !chromeVisible;
      markers.forEach((_marker, index) => applyBadgeState(index));
    }

    // Press H to toggle the HUD out of the way for a screenshot (same as ?hud=0).
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'h' && e.key !== 'H') return;
      if (/^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName)) return;
      chromeVisible = !chromeVisible;
      applyChrome();
    });
  </script>
</body>
</html>
