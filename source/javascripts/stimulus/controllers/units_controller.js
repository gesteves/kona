import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { imperial: String, metric: String }
  
  connect() {
    this.setUnits();
  }

  /**
   * Checks if the user's locale uses imperial units.
   *
   * @returns {boolean} - True if the user's locale is in the imperial locales list, otherwise false.
   */
  isImperialLocale() {
    const imperialLocales = ['en-US'];
    const userLocale = navigator.language;
    return imperialLocales.includes(userLocale);
  }

  /**
   * Sets the content of the element based on the user's locale.
   * If the user's locale is imperial, sets the content to the imperial value,
   * otherwise sets it to the metric value.
   */
  setUnits() {
    if (this.isImperialLocale()) {
      this.element.textContent = this.imperialValue;
    } else {
      this.element.textContent = this.metricValue;
    }
  }
}
