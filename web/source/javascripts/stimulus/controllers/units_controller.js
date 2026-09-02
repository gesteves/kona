import { Controller } from '@hotwired/stimulus';

/** Renders a measurement in the units of the locale of the reader. */
export default class extends Controller {
  static values = { imperial: String, metric: String };

  connect() {
    this.setUnits();
  }

  /**
   * Tells if the locale of the reader uses the imperial units. A `locale` query parameter replaces
   * the locale of the browser, for a debug session. Only the region of the locale decides: a
   * language with no region gets the metric units, and a locale with an extension, for example
   * `en-US-u-ca-gregory`, reads the same as `en-US`.
   * @returns {boolean}
   */
  isImperialLocale() {
    const imperialRegions = ['US', 'LR', 'MM'];
    const urlParams = new URLSearchParams(window.location.search);
    const userLocale = urlParams.get('locale') || navigator.language;

    return imperialRegions.includes(this.regionOf(userLocale));
  }

  /**
   * @param {string} locale - A BCP 47 language tag.
   * @returns {string|null} The region subtag, in upper case, or null.
   */
  regionOf(locale) {
    try {
      return new Intl.Locale(locale).region ?? null;
    } catch {
      return null;
    }
  }

  /** Puts the imperial value or the metric value in the text of the element. */
  setUnits() {
    if (this.isImperialLocale()) {
      this.element.textContent = this.imperialValue;
    } else {
      this.element.textContent = this.metricValue;
    }
  }
}
