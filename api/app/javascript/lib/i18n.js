/**
 * Reads the words that the server put in a `data-admin-i18n` attribute.
 *
 * ⚠️ Each user-facing word of the admin is in config/locales/en.yml, and JavaScript cannot read
 * that file. `AdminHelper#admin_i18n_data` writes the subtree that a controller needs into the
 * markup, and this module reads it. Thus a change to a word is one edit of the locale file.
 *
 * It does the two things that Rails does with a translation: it selects `one` or `other` from a
 * `count`, and it puts each `%{name}` value into the words. It does no more than that.
 */

/**
 * Reads the table of an element.
 *
 * @param {HTMLElement} element The element of the controller.
 * @returns {object} The words, or an empty object when the attribute is absent or is not JSON.
 */
export function i18nTable(element) {
  try {
    return JSON.parse(element.dataset.adminI18n || "{}");
  } catch {
    return {};
  }
}

/**
 * The words of one key.
 *
 * @param {object} table The table from {@link i18nTable}.
 * @param {string} key A key, with a period between each part, as in "geolocation.unknown".
 * @param {object} [options] Each `%{name}` value. A `count` also selects `one` or `other`.
 * @returns {string} The words, or an empty string when the key is absent.
 */
export function t(table, key, options = {}) {
  let value = key.split(".").reduce((node, part) => (node == null ? undefined : node[part]), table);

  // A key with a plural holds `one` and `other`, exactly as the locale file does.
  if (value != null && typeof value === "object") {
    value = options.count === 1 ? value.one : value.other;
  }

  if (typeof value !== "string") return "";

  return value.replace(/%\{(\w+)\}/g, (match, name) =>
    Object.hasOwn(options, name) ? String(options[name]) : match
  );
}
