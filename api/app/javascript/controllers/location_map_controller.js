import { Controller } from "@hotwired/stimulus";

// Pinned, and the only place the version appears. Mapbox GL JS is loaded from Mapbox's own CDN
// rather than bundled: it's several times the size of the whole admin bundle, this is the one page
// that wants it, and the map already can't work without api.mapbox.com, so it adds no new
// dependency — only a second request to a host the page must reach anyway.
const VERSION = "v3.9.0";
const SCRIPT_URL = `https://api.mapbox.com/mapbox-gl-js/${VERSION}/mapbox-gl.js`;
const STYLESHEET_URL = `https://api.mapbox.com/mapbox-gl-js/${VERSION}/mapbox-gl.css`;

// Six decimals is ~11cm, well past what a pin drop or a phone's GPS can mean, and it keeps the
// stored value readable.
const PRECISION = 6;

// What the line above the map shows — ~110m, matching LocationPresenter::DISPLAY_PRECISION so a
// pin drop doesn't reformat the coordinates the server rendered. Display only; PRECISION is stored.
const DISPLAY_PRECISION = 3;

// Mapbox's own default size for the pin.
const MARKER_SCALE = 1;

// ⚠️ Mapbox does **not** scale its default marker offset ([0, -14]) along with `scale`, so at any
// scale but 1 the pin's tip drifts off the coordinate — ~15px below it at 2x. Deriving it here
// keeps the two in step, which is what makes the scale above safe to change.
const MARKER_OFFSET = [ 0, -14 * MARKER_SCALE ];

// Where the map lands when a save didn't start on it — an address, a race shortcut. Close enough
// to see which building you're in. Geolocation isn't in that list: Mapbox's own control flies to
// the reading itself, at a zoom it derives from the reported accuracy.
const LOCATED_ZOOM = 14;

// The saved/unsaved badge. ⚠️ Its "saved" half is also rendered server-side by
// LocationPresenter#state_label / #state_variant; the two have to agree.
const STATES = {
  saved: { label: "Saved", variant: "success" },
  unsaved: { label: "Unsaved", variant: "warning" }
};

const GEOLOCATION_ERRORS = {
  1: "Location permission was denied.",
  2: "Your location isn't available right now.",
  3: "Getting your location timed out."
};

// Module-scoped, so the script is fetched once per full page load however many Turbo visits pass
// through this page. ⚠️ Not `content_for :head`: Turbo merges a new head by *appending* elements,
// so the script would land asynchronously and this controller could connect before `mapboxgl`
// existed. Awaiting the load explicitly has no such race.
let loading = null;

/** @returns {Promise<object>} Mapbox GL JS, loaded on first use. */
function loadMapbox() {
  if (window.mapboxgl) return Promise.resolve(window.mapboxgl);

  loading ||= new Promise((resolve, reject) => {
    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    stylesheet.href = STYLESHEET_URL;
    document.head.appendChild(stylesheet);

    const script = document.createElement("script");
    script.src = SCRIPT_URL;
    script.addEventListener("load", () => resolve(window.mapboxgl));
    script.addEventListener("error", () => {
      loading = null;
      reject(new Error("Mapbox GL JS failed to load"));
    });
    document.head.appendChild(script);
  });

  return loading;
}

/**
 * The admin's location picker: a Mapbox map whose pin is the location about to be saved.
 *
 * Clicking the map, dragging the pin, the Geolocation button, the address box and the race
 * shortcuts all do the same thing — **stage** a coordinate pair. Nothing reaches Redis until Save
 * changes is pressed; that button — and Undo beside it, which throws the staging away — is
 * disabled whenever the staged pair matches the stored one, and the badge beside the coordinates
 * says which of the two states you're in.
 *
 * ⚠️ Only the map itself needs `token`. The address box, the race shortcuts and Save all go through
 * the server and are useful with no map at all, so nothing here may bail out early on a missing one.
 */
export default class extends Controller {
  static targets = ["map", "place", "status", "state", "address", "save", "undo"];
  static values = {
    token: String,
    style: String,
    latitude: String,
    longitude: String,
    center: Array,
    zoom: Number,
    saveUrl: String,
    lookupUrl: String
  };

  connect() {
    // ⚠️ Turbo snapshots the page *before* disconnect, so without this it would cache the map's
    // canvas and a restoration visit would build a second map on top of the dead one.
    this.teardown = this.teardown.bind(this);
    document.addEventListener("turbo:before-cache", this.teardown);

    // What's in Redis, and what the page would write. Equal on arrival, which is what leaves the
    // server-rendered Save and Undo buttons correctly disabled.
    this.stored = this.pair(this.latitudeValue, this.longitudeValue);
    this.staged = this.stored;

    // What the server rendered, so Undo can put the page back when there's nothing stored to return
    // to — rather than restating the presenter's copy here.
    this.initial = {
      place: this.hasPlaceTarget ? this.placeTarget.textContent.trim() : "",
      status: this.hasStatusTarget ? this.statusTarget.textContent.trim() : "",
      label: this.hasStateTarget ? this.stateTarget.textContent.trim() : "",
      variant: this.hasStateTarget ? this.stateTarget.variant : ""
    };

    // The stored location's name, kept so Undo can restore the heading without a second lookup.
    this.storedPlace = this.initial.place;

    if (this.tokenValue) this.start();
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.teardown);
    this.teardown();
  }

  teardown() {
    this.map?.remove();
    this.map = null;
    this.marker = null;
  }

  async start() {
    let mapboxgl;

    try {
      mapboxgl = await loadMapbox();
    } catch {
      this.report("The map couldn't be loaded.");
      return;
    }

    // The visit may have moved on while the script was in flight.
    if (!this.element.isConnected || this.map) return;

    mapboxgl.accessToken = this.tokenValue;
    this.map = new mapboxgl.Map({
      container: this.mapTarget,
      style: this.styleValue,
      center: this.centerValue,
      zoom: this.zoomValue
    });
    this.map.addControl(new mapboxgl.NavigationControl(), "top-right");
    this.map.addControl(this.geolocation(mapboxgl), "top-right");
    this.map.on("click", (event) => this.stage(event.lngLat.lat, event.lngLat.lng));

    this.marker = new mapboxgl.Marker({
      draggable: true,
      scale: MARKER_SCALE,
      offset: MARKER_OFFSET
    });
    this.marker.on("dragend", () => {
      const { lat, lng } = this.marker.getLngLat();
      this.stage(lat, lng);
    });

    this.pin(this.staged);
  }

  /**
   * Mapbox's own Geolocation button, which stages whatever it finds.
   *
   * On the map rather than beside it because the control already does the parts a button of ours
   * had to fake: it flies to the reading, draws its accuracy circle, and **disables itself** where
   * the browser can't geolocate at all — which ours could only discover by being pressed.
   * @returns {object} The control, for addControl.
   */
  geolocation(mapboxgl) {
    const control = new mapboxgl.GeolocateControl({
      positionOptions: { enableHighAccuracy: true, timeout: 10000 },
      // ⚠️ Not `trackUserLocation`. In its active-lock mode the control re-fires on every position
      // update, and every one of those here is a Redis write plus a LocationSyncJob — so a phone
      // left on this page would sync itself to Intervals.icu on GPS jitter. One press, one reading.
      trackUserLocation: false
    });

    // ⚠️ No `fly`: the control has already flown the map there, and flying again from our side
    // fights its animation.
    control.on("geolocate", ({ coords }) => this.stage(coords.latitude, coords.longitude));
    control.on("error", (error) =>
      this.report(GEOLOCATION_ERRORS[error.code] ?? "Your location couldn't be read.")
    );

    return control;
  }

  /**
   * Geocodes whatever is in the address box and stages the result. The lookup writes nothing, so
   * hunting for a place costs no more than moving the pin around does.
   * @param {SubmitEvent} event
   */
  async search(event) {
    // ⚠️ The form has no action, so without this Enter reloads the page.
    event.preventDefault();

    const address = this.hasAddressTarget ? this.addressTarget.value.trim() : "";
    if (!address) return this.report("Type an address first.");

    this.report("Looking that up…");
    const result = await this.read({ address }, "That address couldn't be found.");
    if (!result) return;

    this.stage(result.latitude, result.longitude, { fly: true, place: result.place });
  }

  /**
   * A race shortcut. The coordinates are Contentful's own, carried on the button.
   * @param {PointerEvent} event
   */
  useRace(event) {
    const { latitude, longitude } = event.currentTarget.dataset;
    this.stage(Number(latitude), Number(longitude), { fly: true });
  }

  /**
   * Stages a location: the pin moves there, the heading previews the name it resolves to, and Save
   * changes wakes up. Nothing is written.
   * @param {boolean} [options.fly] Whether to move the map too, for a stage that didn't start on it.
   * @param {string} [options.place] A name already resolved by the caller, saving a second lookup.
   */
  stage(latitude, longitude, { fly = false, place } = {}) {
    const staged = this.pair(latitude, longitude);
    if (!staged) return;

    this.staged = staged;
    this.pin(staged);
    if (fly) this.map?.flyTo({ center: [ staged[1], staged[0] ], zoom: LOCATED_ZOOM });

    this.settle();
    if (place === undefined) this.preview(staged); else this.describe(place || this.format(staged));
  }

  /**
   * Writes the staged location. The action validates and stores it exactly as POST /api/location
   * does, and answers with the place name the weather widget would use.
   */
  async save() {
    if (!this.staged || !this.changed) return;

    const staged = this.staged;
    this.report("Saving…");

    const result = await this.write(staged, "Those coordinates were refused.");
    if (!result) return;

    // ⚠️ Against `staged`, not `this.staged`: the pin may have moved again while the request was in
    // flight, and marking *that* pair stored would disable Save over an unsaved change.
    this.stored = staged;
    this.storedPlace = result.place || this.format(staged);
    this.describe(this.storedPlace);
    this.settle();
  }

  /**
   * Throws the staged location away. The pin, the map and the heading go back to what's stored —
   * or, where nothing is stored yet, to the empty page the server rendered.
   */
  undo() {
    if (!this.changed) return;

    if (this.stored) {
      return this.stage(this.stored[0], this.stored[1], { fly: true, place: this.storedPlace });
    }

    this.staged = null;
    this.marker?.remove();
    this.describe(this.initial.place);
    this.report(this.initial.status);
    this.flag(this.initial);
    this.settle();
  }

  /**
   * Names the staged location under the heading — the same name the weather widget would print, so
   * the page previews it before it's committed. A failed lookup leaves the last name alone rather
   * than blanking the heading.
   */
  async preview(staged) {
    const result = await this.read({ latitude: staged[0], longitude: staged[1] });
    // The pin may have moved on while this was in flight; a late answer must not caption a place
    // that's no longer staged.
    if (!result || this.key(this.staged) !== this.key(staged)) return;

    this.describe(result.place || this.format(staged));
  }

  /** Puts the badge, the two buttons and the coordinates in step with what's staged. */
  settle() {
    const pending = this.changed;
    if (this.hasSaveTarget) this.saveTarget.disabled = !pending;
    if (this.hasUndoTarget) this.undoTarget.disabled = !pending;

    // Undone back to nothing: the caller has already restored the line the server rendered, and
    // there are no coordinates to print over it.
    if (!this.staged) return;

    this.flag(pending ? STATES.unsaved : STATES.saved);
    this.report(this.format(this.staged));
  }

  /** @param {object} state One of STATES. */
  flag(state) {
    if (!this.hasStateTarget) return;

    this.stateTarget.textContent = state.label;
    this.stateTarget.variant = state.variant;
  }

  /** @returns {boolean} Whether the staged location differs from the stored one. */
  get changed() {
    return this.key(this.staged) !== this.key(this.stored);
  }

  /** Compares pairs by value — they're rounded, so this is exact. */
  key(pair) {
    return pair ? pair.join(",") : "";
  }

  /** Puts the marker on the map, adding it the first time. */
  pin(pair) {
    if (pair) this.marker?.setLngLat([ pair[1], pair[0] ]).addTo(this.map);
  }

  /**
   * GETs the lookup action, which resolves a location without storing it.
   * @param {object} query Either an address, or a coordinate pair.
   * @param {string} [refusal] What to report when the server can't resolve it. Omitted for the
   *   background preview, which has nothing worth interrupting the status line for.
   * @returns {Promise<object|null>}
   */
  async read(query, refusal) {
    try {
      const response = await fetch(`${this.lookupUrlValue}?${new URLSearchParams(query)}`, {
        headers: { Accept: "application/json" }
      });

      if (!response.ok) {
        if (refusal) this.report(refusal);
        return null;
      }

      return await response.json();
    } catch {
      if (refusal) this.report("Couldn't reach the server.");
      return null;
    }
  }

  /**
   * POSTs the save action, the one call here that writes.
   * @returns {Promise<object|null>} The stored location, or null if nothing was saved.
   */
  async write(pair, refusal) {
    try {
      const response = await fetch(this.saveUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        body: new URLSearchParams({ latitude: pair[0], longitude: pair[1] })
      });

      if (!response.ok) {
        this.report(refusal);
        return null;
      }

      return await response.json();
    } catch {
      this.report("Couldn't reach the server. Nothing was saved.");
      return null;
    }
  }

  describe(place) {
    if (this.hasPlaceTarget) this.placeTarget.textContent = place;
  }

  report(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message;
  }

  /**
   * Parses and rounds a coordinate pair.
   * ⚠️ Tested for finiteness, not truthiness: 0 is a real coordinate, and the values arrive as
   * strings that are empty when nothing is stored yet.
   * @returns {number[]|null} The rounded pair, or null if either half is unusable.
   */
  pair(latitude, longitude) {
    const [ lat, lng ] = [ Number(latitude), Number(longitude) ];
    if (latitude === "" || longitude === "") return null;
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;

    return [ this.round(lat), this.round(lng) ];
  }

  round(value) {
    return Number(Number(value).toFixed(PRECISION));
  }

  /**
   * The pair as a human reads it, rounded for display only — what gets saved keeps PRECISION.
   * @returns {string}
   */
  format(pair) {
    return pair.map((value) => Number(value.toFixed(DISPLAY_PRECISION))).join(", ");
  }
}
