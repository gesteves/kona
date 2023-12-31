import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { imperial: String, metric: String }
  
  connect() {
    this.setUnits();
  }

  isImperialLocale() {
    const imperialLocales = ['en-US'];
    const userLocale = navigator.language;
    return imperialLocales.includes(userLocale);
  }

  setUnits() {
    if (this.isImperialLocale()) {
      this.element.textContent = this.imperialValue;
    } else {
      this.element.textContent = this.metricValue;
    }
  }
}
