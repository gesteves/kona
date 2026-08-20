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
 * The admin's location picker: a Mapbox map whose pin is the current location.
 *
 * Clicking the map, dragging the pin, the Geolocation button, the address box and the race
 * shortcuts all do the same thing — post to the same action the bearer-gated POST /api/location
 * uses. There is no separate save step, so a stray click is undone by clicking where you meant to,
 * and the line above the controls is the only confirmation there is.
 *
 * ⚠️ Only the map itself needs `token`. The address box and the race shortcuts save through the
 * server and are useful with no map at all, so nothing here may bail out early on a missing one.
 */
export default class extends Controller {
  static targets = ["map", "place", "status", "address"];
  static values = {
    token: String,
    style: String,
    latitude: String,
    longitude: String,
    center: Array,
    zoom: Number,
    saveUrl: String
  };

  connect() {
    // ⚠️ Turbo snapshots the page *before* disconnect, so without this it would cache the map's
    // canvas and a restoration visit would build a second map on top of the dead one.
    this.teardown = this.teardown.bind(this);
    document.addEventListener("turbo:before-cache", this.teardown);

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
    this.map.on("click", (event) => this.moveTo(event.lngLat.lat, event.lngLat.lng));

    this.marker = new mapboxgl.Marker({
      draggable: true,
      scale: MARKER_SCALE,
      offset: MARKER_OFFSET
    });
    this.marker.on("dragend", () => {
      const { lat, lng } = this.marker.getLngLat();
      this.moveTo(lat, lng);
    });

    this.pin(this.latitudeValue, this.longitudeValue);
  }

  /**
   * Mapbox's own Geolocation button, which saves whatever it finds.
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

    // ⚠️ moveTo, not goTo: the control has already flown the map there, and flying again from our
    // side fights its animation.
    control.on("geolocate", ({ coords }) => this.moveTo(coords.latitude, coords.longitude));
    control.on("error", (error) =>
      this.report(GEOLOCATION_ERRORS[error.code] ?? "Your location couldn't be read.")
    );

    return control;
  }

  /**
   * Geocodes whatever is in the address box, then goes there. The server geocodes *and* stores in
   * one call, so the coordinates come back already saved and there is nothing to post twice.
   * @param {SubmitEvent} event
   */
  async search(event) {
    // ⚠️ The form has no action, so without this Enter reloads the page.
    event.preventDefault();

    const address = this.hasAddressTarget ? this.addressTarget.value.trim() : "";
    if (!address) return this.report("Type an address first.");

    this.report("Looking that up…");
    const result = await this.write({ address }, "That address couldn't be found.");
    if (!result) return;

    this.settle(result.latitude, result.longitude, result.place, { fly: true });
  }

  /**
   * A race shortcut. The coordinates are Contentful's own, carried on the button, so this is an
   * ordinary save with the map flown along to it.
   * @param {PointerEvent} event
   */
  useRace(event) {
    const { latitude, longitude } = event.currentTarget.dataset;
    this.goTo(Number(latitude), Number(longitude));
  }

  /** Flies the map to a point and saves it. */
  goTo(latitude, longitude) {
    this.map?.flyTo({ center: [longitude, latitude], zoom: LOCATED_ZOOM });
    this.moveTo(latitude, longitude);
  }

  /** Moves the pin to a new position and saves it. */
  moveTo(latitude, longitude) {
    const rounded = [this.round(latitude), this.round(longitude)];

    this.pin(...rounded);
    this.save(...rounded);
  }

  /** Puts the marker on the map, adding it the first time. */
  pin(latitude, longitude) {
    const [lat, lng] = [Number(latitude), Number(longitude)];
    // ⚠️ Tested for finiteness, not truthiness: 0 is a real coordinate, and the values arrive as
    // strings that are empty when nothing is stored yet.
    if (latitude === "" || longitude === "" || !Number.isFinite(lat) || !Number.isFinite(lng)) {
      return;
    }

    this.marker?.setLngLat([lng, lat]).addTo(this.map);
  }

  /**
   * Writes the location. The action validates and stores it exactly as POST /api/location does,
   * and answers with the place name the weather widget would use — so the heading describes the
   * pin that's on the map now, not the one the page was loaded with.
   * @param {number} latitude
   * @param {number} longitude
   */
  async save(latitude, longitude) {
    this.report("Saving…");
    const result = await this.write({ latitude, longitude }, "Those coordinates were refused.");
    if (!result) return;

    this.settle(latitude, longitude, result.place);
  }

  /**
   * Posts to the save action, which both validates and stores. The one place that talks to the
   * server, so an address and a coordinate pair fail the same way.
   * @param {object} body The form fields to send — a coordinate pair, or an address.
   * @param {string} refusal What to report when the server rejects the request.
   * @returns {Promise<object|null>} The saved location, or null if nothing was saved.
   */
  async write(body, refusal) {
    try {
      const response = await fetch(this.saveUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        body: new URLSearchParams(body)
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

  /**
   * Reflects a saved location in the heading and the status line.
   * @param {boolean} [options.fly] Whether to move the map and the pin as well. Only the address
   *   path needs it — every other save starts by moving the pin itself.
   */
  settle(latitude, longitude, place, { fly = false } = {}) {
    const coordinates = this.format(latitude, longitude);

    if (fly) {
      this.pin(latitude, longitude);
      this.map?.flyTo({ center: [Number(longitude), Number(latitude)], zoom: LOCATED_ZOOM });
    }

    this.describe(place || coordinates);
    this.report(`Saved · ${coordinates}`);
  }

  describe(place) {
    if (this.hasPlaceTarget) this.placeTarget.textContent = place;
  }

  report(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message;
  }

  round(value) {
    return Number(Number(value).toFixed(PRECISION));
  }

  /**
   * The pair as a human reads it, rounded for display only — what was saved keeps PRECISION.
   * @returns {string}
   */
  format(latitude, longitude) {
    return [latitude, longitude]
      .map((value) => Number(Number(value).toFixed(DISPLAY_PRECISION)))
      .join(", ");
  }
}
