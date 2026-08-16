import { Controller } from "@hotwired/stimulus";

/**
 * Collapses a four-sided value (padding, extra map) into one field while every side matches.
 *
 * All four fields stay in the DOM and stay named, so the form always submits four values — three
 * are only hidden. While linked, the first field's value is mirrored into the other three.
 *
 * ⚠️ The mirror runs on the first field's own `input` event, which fires at the target before it
 * reaches the form. That ordering is what lets the preview controller, listening on the form, read
 * the already-mirrored values.
 */
export default class extends Controller {
  static targets = ["toggle", "primary", "extra"];
  static values = { linkedLabel: String };

  connect() {
    this.onToggle = this.onToggle.bind(this);
    this.onInput = this.onInput.bind(this);
    this.toggleTarget.addEventListener("change", this.onToggle);
    this.primaryTarget.addEventListener("input", this.onInput);
    this.sideLabel = this.primaryTarget.getAttribute("label");
    this.render();
  }

  disconnect() {
    this.toggleTarget.removeEventListener("change", this.onToggle);
    this.primaryTarget.removeEventListener("input", this.onInput);
  }

  onToggle() {
    this.render();
    if (this.linked) this.mirror();
  }

  onInput() {
    if (this.linked) this.mirror();
  }

  /** @returns {boolean} Whether every side is being driven by the first field. */
  get linked() {
    return this.toggleTarget.checked;
  }

  render() {
    this.element.classList.toggle("sides--linked", this.linked);
    // Reading "Padding" over one box beats reading "Top" over a box that also sets the other three.
    this.primaryTarget.label = this.linked ? this.linkedLabelValue : this.sideLabel;
  }

  mirror() {
    this.extraTargets.forEach((field) => {
      field.value = this.primaryTarget.value;
    });
  }
}
