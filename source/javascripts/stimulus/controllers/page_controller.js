import { trackPageView } from '../lib/analytics';
import { isProduction } from '../lib/context';
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  load() {
    if (isProduction()) {
      trackPageView();
    }
  }
}
