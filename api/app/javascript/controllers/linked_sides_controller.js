import { Controller } from "@hotwired/stimulus";

/**
 * Shows a value for four sides, for example the padding or the extra map, in one field while the
 * four values are the same.
 *
 * All four fields stay in the DOM and keep their names, thus the form always submits four values.
 * The code only hides three of them. While the four fields are together, the value of the first
 * field goes into the other three.
 *
 * ⚠️ The copy runs on the `input` event of the first field, and that event occurs at the field
 * before it reaches the form. That order is what lets the preview controller, which listens on the
 * form, read the values after the copy.
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

  /** @returns {boolean} True if the first field gives the value of each side. */
  get linked() {
    return this.toggleTarget.checked;
  }

  render() {
    this.element.classList.toggle("sides--linked", this.linked);
    // "Padding" above one box is better than "Top" above a box that also sets the other three.
    this.primaryTarget.label = this.linked ? this.linkedLabelValue : this.sideLabel;
  }

  mirror() {
    this.extraTargets.forEach((field) => {
      field.value = this.primaryTarget.value;
    });
  }
}
