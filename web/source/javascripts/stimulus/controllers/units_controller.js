import { Controller } from '@hotwired/stimulus';

/** Renders a measurement in the units of the locale of the reader. */
export default class extends Controller {
  static values = { imperial: String, metric: String };

  connect() {
    this.setUnits();
  }

  /**
   * Tells if the locale of the reader uses the imperial units. A `locale` query parameter replaces
   * the locale of the browser, for a debug session.
   * @returns {boolean}
   */
  isImperialLocale() {
    const imperialLocales = ['en-us', 'en-lr'];
    const urlParams = new URLSearchParams(window.location.search);
    const localeQueryParam = urlParams.get('locale')?.toLowerCase();
    const userLocale = localeQueryParam || navigator.language.toLowerCase();

    return imperialLocales.includes(userLocale);
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
