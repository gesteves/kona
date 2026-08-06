import { Controller } from '@hotwired/stimulus';

/** Renders a measurement in the units matching the reader's locale. */
export default class extends Controller {
  static values = { imperial: String, metric: String };

  connect() {
    this.setUnits();
  }

  /**
   * Whether the reader's locale uses imperial units. A `locale` query param overrides the
   * browser's, for debugging.
   * @returns {boolean}
   */
  isImperialLocale() {
    const imperialLocales = ['en-us', 'en-lr'];
    const urlParams = new URLSearchParams(window.location.search);
    const localeQueryParam = urlParams.get('locale')?.toLowerCase();
    const userLocale = localeQueryParam || navigator.language.toLowerCase();

    return imperialLocales.includes(userLocale);
  }

  /** Sets the element's text to the imperial or metric value. */
  setUnits() {
    if (this.isImperialLocale()) {
      this.element.textContent = this.imperialValue;
    } else {
      this.element.textContent = this.metricValue;
    }
  }
}
