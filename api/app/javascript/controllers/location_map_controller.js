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

// Close enough to see which building you're in, for a reading from the Geolocation API.
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
 * Clicking the map, dragging the pin, and the Geolocation button all do the same thing — post to
 * the same action the bearer-gated POST /api/location uses. There is no separate save step, so a
 * stray click is undone by clicking where you meant to, and the line above the map is the only
 * confirmation there is.
 */
export default class extends Controller {
  static targets = ["map", "place", "status"];
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
    this.map.on("click", (event) => this.moveTo(event.lngLat.lat, event.lngLat.lng));

    // Twice Mapbox's default size: the pin is the one thing on this page you have to be able to
    // find and grab, and at 1x it disappears into a busy streets basemap.
    this.marker = new mapboxgl.Marker({ draggable: true, scale: 2 });
    this.marker.on("dragend", () => {
      const { lat, lng } = this.marker.getLngLat();
      this.moveTo(lat, lng);
    });

    this.pin(this.latitudeValue, this.longitudeValue);
  }

  /** Asks the browser where it is, then saves that. */
  locate() {
    if (!navigator.geolocation) return this.report("This browser can't share a location.");

    this.report("Finding you…");
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => {
        this.map?.flyTo({ center: [coords.longitude, coords.latitude], zoom: LOCATED_ZOOM });
        this.moveTo(coords.latitude, coords.longitude);
      },
      (error) => this.report(GEOLOCATION_ERRORS[error.code] ?? "Your location couldn't be read."),
      { enableHighAccuracy: true, timeout: 10000 }
    );
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
    const coordinates = this.format(latitude, longitude);
    this.report("Saving…");

    try {
      const response = await fetch(this.saveUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        body: new URLSearchParams({ latitude, longitude })
      });

      if (!response.ok) return this.report("Those coordinates were refused.");

      const { place } = await response.json();
      this.describe(place || coordinates);
      this.report(`Saved · ${coordinates}`);
    } catch {
      this.report("Couldn't reach the server. Nothing was saved.");
    }
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
