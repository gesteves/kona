import { Controller } from "@hotwired/stimulus";

/**
 * Controller for dynamically setting unit measurements based on the user's locale.
 */
export default class extends Controller {
  static values = { imperial: String, metric: String }

  /**
   * Sets the units of measurement based on the user's locale when the controller is connected.
   */
  connect() {
    this.setUnits();
  }

  /**
   * Checks if the user's locale uses imperial units, based on the locale set by the browser.
   * Also accepts a locale from a `locale` query parameter, for debugging.
   * @returns {boolean} True if the user's locale uses imperial units, otherwise false.
   */
  isImperialLocale() {
    // I think only the US and Liberia use imperial units at this point?
    const imperialLocales = ['en-us', 'en-lr'];
    const urlParams = new URLSearchParams(window.location.search);
    const localeQueryParam = urlParams.get('locale')?.toLowerCase();
    const userLocale = localeQueryParam || navigator.language.toLowerCase();

    return imperialLocales.includes(userLocale);
  }

  /**
   * Sets the content of the element based on the user's locale.
   */
  setUnits() {
    if (this.isImperialLocale()) {
      this.element.textContent = this.imperialValue;
    } else {
      this.element.textContent = this.metricValue;
    }
  }
}
