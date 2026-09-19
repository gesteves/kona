/**
 * The CSRF token of the page, as a header for a `fetch` that posts.
 *
 * ⚠️ The admin does not skip the forgery protection, thus each POST from a script needs this.
 * `csrf_meta_tags` renders nothing where that protection is off, which is the test environment.
 * Thus this gives an empty object there and the header is absent.
 * @returns {object}
 */
export function csrfHeader() {
  const token = document.querySelector("meta[name='csrf-token']")?.content;

  return token ? { "X-CSRF-Token": token } : {};
}
