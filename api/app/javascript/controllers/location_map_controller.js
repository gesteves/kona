import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";

// This is the only place with the version. The code loads Mapbox GL JS from the CDN of Mapbox and
// does not put it in the bundle: it is several times the size of the full admin bundle, this is
// the one page that needs it, and the map cannot work without api.mapbox.com. Thus it adds no new
// dependency, only a second request to a host that the page must reach.
const VERSION = "v3.9.0";
const SCRIPT_URL = `https://api.mapbox.com/mapbox-gl-js/${VERSION}/mapbox-gl.js`;
const STYLESHEET_URL = `https://api.mapbox.com/mapbox-gl-js/${VERSION}/mapbox-gl.css`;

// Six decimals is approximately 11cm, which is more accurate than a pin or the GPS of a phone.
// It also keeps the stored value easy to read.
const PRECISION = 6;

// The accuracy of the line above the map, approximately 110m. It agrees with
// LocationPresenter::DISPLAY_PRECISION, thus a pin does not change the format of the coordinates
// that the server rendered. This applies only to the screen. The app stores PRECISION.
const DISPLAY_PRECISION = 3;

// The default size of the Mapbox pin.
const MARKER_SCALE = 1;

// ⚠️ Mapbox does **not** change its default marker offset ([0, -14]) with `scale`. Thus at each
// scale but 1, the point of the pin moves away from the coordinate, approximately 15px below it at
// 2x. This code calculates the offset, thus the two agree and you can change the scale above.
const MARKER_OFFSET = [ 0, -14 * MARKER_SCALE ];

// The zoom of the map when a save does not start on the map, that is, an address or a race
// shortcut. It is near enough to show which building you are in. Geolocation is not in that list:
// the Mapbox control moves to the reading itself, at a zoom that it makes from the accuracy.
const LOCATED_ZOOM = 14;

// The saved or unsaved badge. ⚠️ LocationPresenter#state_label and #state_variant also render its
// "saved" half on the server. The two must agree.
// ⚠️ Only the VARIANT is here. The words come from `admin.location.state.*`, which
// `LocationPresenter#state_label` also reads, thus the two cannot become different.
const STATE_VARIANTS = { saved: "success", unsaved: "warning" };

// This is at the module level, thus the code gets the script one time for each full page load,
// for any number of Turbo visits through this page. ⚠️ Do not use `content_for :head`: Turbo adds
// the elements of a new head at the end, thus the script would arrive later and this controller
// could connect before `mapboxgl` existed. An explicit wait for the load has no such race.
let loading = null;

/** @returns {Promise<object>} Mapbox GL JS. The code loads it at the first use. */
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
      // The next attempt adds both elements again, thus this one takes its own away.
      loading = null;
      stylesheet.remove();
      script.remove();
      reject(new Error("Mapbox GL JS failed to load"));
    });
    document.head.appendChild(script);
  });

  return loading;
}

/**
 * The location picker of the admin: a Mapbox map, and its pin is the location to save.
 *
 * A click on the map, a move of the pin, the Geolocation button, the address box, and the race
 * shortcuts all do the same thing: they **stage** a pair of coordinates. Nothing goes to Redis
 * until you press Save changes. That button, and Undo beside it, which removes the staged pair,
 * are both off when the staged pair is the same as the stored pair. The badge beside the
 * coordinates says which of the two states you are in.
 *
 * ⚠️ Only the map needs `token`. The address box, the race shortcuts, and Save all go through the
 * server and are useful with no map. Thus no code here can stop early when there is no token.
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
    // ⚠️ Turbo makes its snapshot of the page *before* the disconnect. Without this code, the
    // snapshot would contain the canvas of the map, and a restoration visit would make a second
    // map on top of the first one.
    this.teardown = this.teardown.bind(this);
    document.addEventListener("turbo:before-cache", this.teardown);

    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute. `state`
    // holds the SAME keys that `LocationPresenter#state_label` reads, thus the badge of the server
    // and the badge of the browser cannot become different.
    this.i18n = i18nTable(this.element);

    // The value in Redis, and the value that the page would write. They are the same at the first
    // render, which is why the server renders the Save and Undo buttons in the off state.
    this.stored = this.pair(this.latitudeValue, this.longitudeValue);
    this.staged = this.stored;

    // The text that the server rendered. Thus Undo can put the page back when there is no stored
    // location, and this file does not repeat the text of the presenter.
    this.initial = {
      place: this.hasPlaceTarget ? this.placeTarget.textContent.trim() : "",
      status: this.hasStatusTarget ? this.statusTarget.textContent.trim() : "",
      label: this.hasStateTarget ? this.stateTarget.textContent.trim() : "",
      variant: this.hasStateTarget ? this.stateTarget.variant : ""
    };

    // The name of the stored location. The code keeps it, thus Undo can put the heading back with
    // no second lookup.
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
      this.report(this.words("map_failed"));
      return;
    }

    // The visit can change while the browser gets the script.
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
   * The Geolocation button of Mapbox. It stages the location that it finds.
   *
   * It is on the map, and not beside it, because the control already does the parts that a button
   * of ours had to copy: it moves to the reading, draws its accuracy circle, and **turns itself
   * off** where the browser cannot geolocate. Our button could find that only after a press.
   * @returns {object} The control, for addControl.
   */
  geolocation(mapboxgl) {
    const control = new mapboxgl.GeolocateControl({
      positionOptions: { enableHighAccuracy: true, timeout: 10000 },
      // ⚠️ Do not use `trackUserLocation`. In its active-lock mode the control sends an event for
      // each position update, and each event here is a Redis write and a LocationSyncJob. Thus a
      // phone on this page would sync itself to Intervals.icu on each small GPS change. One press
      // must give one reading.
      trackUserLocation: false
    });

    // ⚠️ Do not use `fly`. The control already moved the map there, and a second move from this
    // code would stop its animation.
    control.on("geolocate", ({ coords }) => this.stage(coords.latitude, coords.longitude));
    control.on("error", (error) =>
      this.report(this.words(`geolocation.${error.code}`) || this.words("geolocation.unknown"))
    );

    return control;
  }

  /**
   * Geocodes the text in the address box and stages the result. The lookup writes nothing, thus a
   * search for a place costs the same as a move of the pin.
   * @param {SubmitEvent} event
   */
  async search(event) {
    // ⚠️ The form has no action. Without this code, Enter loads the page again.
    event.preventDefault();

    const address = this.hasAddressTarget ? this.addressTarget.value.trim() : "";
    if (!address) return this.report(this.words("need_address"));

    this.report(this.words("searching"));
    // ⚠️ Two searches in a row must not let the slower answer win. It is the rule of preview().
    this.searchSeq = (this.searchSeq ?? 0) + 1;
    const seq = this.searchSeq;
    const result = await this.read({ address }, this.words("address_not_found"));
    if (!result || seq !== this.searchSeq) return;

    this.stage(result.latitude, result.longitude, { fly: true, place: result.place });
  }

  /**
   * A race shortcut. The coordinates come from Contentful and are on the button.
   * @param {PointerEvent} event
   */
  useRace(event) {
    const { latitude, longitude } = event.currentTarget.dataset;
    this.stage(Number(latitude), Number(longitude), { fly: true });
  }

  /**
   * Stages a location: the pin moves there, the heading shows the name of that location, and Save
   * changes becomes available. This writes nothing.
   * @param {boolean} [options.fly] True to move the map also, for a stage that did not start on it.
   * @param {string} [options.place] A name that the caller already found. It saves a second
   *   lookup.
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
   * Writes the staged location. The action checks it and stores it in the same way as
   * POST /api/location, and it answers with the place name that the weather widget would use.
   */
  async save() {
    if (!this.staged || !this.changed) return;

    const staged = this.staged;
    this.report(this.words("saving"));

    const result = await this.write(staged, this.words("refused"));
    if (!result) return;

    // ⚠️ Compare with `staged`, not with `this.staged`. The pin can move again during the request,
    // and a mark of *that* pair as stored would turn Save off for a change that is not saved.
    this.stored = staged;
    this.storedPlace = result.place || this.format(staged);
    this.describe(this.storedPlace);
    this.settle();
  }

  /**
   * Removes the staged location. The pin, the map, and the heading go back to the stored location,
   * or, when there is no stored location, to the empty page that the server rendered.
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
   * Puts the name of the staged location below the heading. It is the same name that the weather
   * widget would show, thus the page previews it before the save. A lookup that fails keeps the
   * last name, and does not make the heading empty.
   */
  async preview(staged) {
    const result = await this.read({ latitude: staged[0], longitude: staged[1] });
    // The pin can move during this request. A late answer must not name a place that is no longer
    // staged.
    if (!result || this.key(this.staged) !== this.key(staged)) return;

    this.describe(result.place || this.format(staged));
  }

  /** Makes the badge, the two buttons, and the coordinates agree with the staged location. */
  settle() {
    const pending = this.changed;
    if (this.hasSaveTarget) this.saveTarget.disabled = !pending;
    if (this.hasUndoTarget) this.undoTarget.disabled = !pending;

    // Undo went back to no location. The caller already put back the line that the server
    // rendered, and there are no coordinates to write over it.
    if (!this.staged) return;

    this.flag(pending ? "unsaved" : "saved");
    this.report(this.format(this.staged));
  }

  /**
   * Writes the badge of one state.
   * @param {string|object} state A name of STATE_VARIANTS, or the `{label, variant}` that the
   *   server rendered, which Undo puts back when there is no stored location.
   */
  flag(state) {
    if (!this.hasStateTarget) return;

    const label = typeof state === "string" ? this.words(`state.${state}`) : state.label;
    const variant = typeof state === "string" ? STATE_VARIANTS[state] : state.variant;

    this.stateTarget.textContent = label;
    this.stateTarget.variant = variant;
  }

  /**
   * One line of words from the locale file.
   * @param {string} key A key below the table of this controller.
   * @returns {string}
   */
  words(key) {
    return t(this.i18n, key);
  }

  /** @returns {boolean} True if the staged location is different from the stored one. */
  get changed() {
    return this.key(this.staged) !== this.key(this.stored);
  }

  /** Compares two pairs by value. They are rounded, thus the comparison is exact. */
  key(pair) {
    return pair ? pair.join(",") : "";
  }

  /** Puts the marker on the map. It adds the marker at the first call. */
  pin(pair) {
    if (pair) this.marker?.setLngLat([ pair[1], pair[0] ]).addTo(this.map);
  }

  /**
   * GETs the lookup action, which finds a location and does not store it.
   * @param {object} query An address, or a pair of coordinates.
   * @param {string} [refusal] The message to show when the server cannot find the location. Omit
   *   it for the background preview, which has no message that is important enough for the status
   *   line.
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
      if (refusal) this.report(this.words("unreachable"));
      return null;
    }
  }

  /**
   * POSTs the save action, which is the one call here that writes.
   * @returns {Promise<object|null>} The stored location, or null if the code saved nothing.
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
      this.report(this.words("unreachable_save"));
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
   * Parses and rounds a pair of coordinates.
   * ⚠️ The code tests that each value is finite, and not that it is true. 0 is a real coordinate,
   * and the values come as strings that are empty when there is no stored location.
   * @returns {number[]|null} The rounded pair, or null if one of the two values is incorrect.
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
   * The pair in a form that a person reads. The code rounds it only for the screen. The save
   * keeps PRECISION.
   * @returns {string}
   */
  format(pair) {
    return pair.map((value) => Number(value.toFixed(DISPLAY_PRECISION))).join(", ");
  }
}
