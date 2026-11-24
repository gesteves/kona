/**
 * The CSRF token of the page, as a header for a `fetch` that posts.
 *
 * ⚠️ The admin does not skip the forgery protection, thus each POST from a script needs this.
 * `csrf_meta_tags` renders nothing in the test environment, where that protection is off.
 * @returns {object} The header, or an empty object when the page has no token.
 */
export function csrfHeader() {
  const token = document.querySelector("meta[name='csrf-token']")?.content;

  return token ? { "X-CSRF-Token": token } : {};
}
