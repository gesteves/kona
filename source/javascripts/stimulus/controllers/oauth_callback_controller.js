import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  static targets = ['input'];

  connect() {
    this.extractAuthorizationCode();
  }

  extractAuthorizationCode() {
    const urlParams = new URLSearchParams(window.location.search);
    const code = urlParams.get('code');
    const error = urlParams.get('error');

    if (error) {
      this.inputTarget.value = '';
      this.inputTarget.placeholder = 'Error: No authorization code received';
    } else if (code) {
      this.inputTarget.value = code;
    } else {
      this.inputTarget.value = '';
      this.inputTarget.placeholder = 'No authorization code found';
    }
  }
}
