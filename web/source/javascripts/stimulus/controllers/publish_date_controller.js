import { Controller } from '@hotwired/stimulus';

// One formatter for each timezone, for the whole page. A listing page has one controller for each
// card, and each render made two formatters.
const dateFormatters = new Map();

/**
 * @param {string} timeZone - An IANA timezone id, or an empty string for the zone of the viewer.
 * @returns {Intl.DateTimeFormat}
 */
function dateFormatter(timeZone) {
  if (!dateFormatters.has(timeZone)) {
    let formatter;
    try {
      formatter = new Intl.DateTimeFormat('en-CA', {
        timeZone: timeZone || undefined,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      });
    } catch {
      // ⚠️ A TIME_ZONE with a mistake raises here, and that would remove each badge and each
      // clock on the site. The zone of the viewer is the fallback.
      formatter = new Intl.DateTimeFormat('en-CA', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      });
    }
    dateFormatters.set(timeZone, formatter);
  }
  return dateFormatters.get(timeZone);
}

/**
 * Renders in the browser the parts of the meta line of an article that depend on the publish date.
 * Thus they stay correct with no new build: the "New" badge, the clock icon or the calendar icon,
 * and the relative time or the absolute time in the permalink.
 *
 * The server renders each state. The calendar icon and the absolute date are visible by default,
 * which is the result with no JavaScript, and the clock icon and the "New" badge are in the page but
 * hidden. This controller shows the correct ones for the current date in the timezone of the site.
 */
export default class extends Controller {
  static targets = ['badge', 'clock', 'calendar', 'timestamp'];
  static values = {
    datetime: String, // ISO8601 publish instant
    timeZone: String, // IANA timezone the dates are reckoned in (the site owner's location)
    entryType: String, // 'Article' or 'Short'
    draft: { type: Boolean, default: false },
  };

  connect() {
    if (!this.hasDatetimeValue) {
      return;
    }
    // ⚠️ A Turbo restoration visit renders a snapshot that holds the <wa-relative-time>, whose
    // text is in a shadow root. Thus the text is empty there, and the absolute date must come
    // from the value instead.
    if (
      this.hasTimestampTarget &&
      !this.timestampTarget.querySelector('wa-relative-time')
    ) {
      this.absoluteTimestamp = this.timestampTarget.textContent;
    }
    this.render();
  }

  disconnect() {
    if (this.timer) {
      clearTimeout(this.timer);
    }
  }

  render() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }

    const today = this.publishedOn() === this.todayOn();
    const recent = today || this.draftValue;

    if (this.hasBadgeTarget) {
      this.badgeTarget.hidden = !this.isNew(today);
    }
    if (this.hasClockTarget) {
      this.clockTarget.hidden = !recent;
    }
    if (this.hasCalendarTarget) {
      this.calendarTarget.hidden = recent;
    }
    if (this.hasTimestampTarget) {
      this.renderTimestamp(recent);
    }
  }

  /**
   * Shows a relative time that changes by itself for a recent article, or the absolute date from
   * the server for an older article. The relative time is a <wa-relative-time> element, which
   * updates itself. This code still renders each minute, thus the display changes to the absolute
   * date when the article is no longer from today.
   * @param {boolean} relative
   */
  renderTimestamp(relative) {
    if (!relative) {
      this.timestampTarget.textContent =
        this.absoluteTimestamp || this.absoluteDate();
      return;
    }
    if (!this.timestampTarget.querySelector('wa-relative-time')) {
      const relativeTime = document.createElement('wa-relative-time');
      relativeTime.setAttribute(
        'date',
        new Date(this.datetimeValue).toISOString()
      );
      relativeTime.setAttribute('sync', '');
      this.timestampTarget.replaceChildren(relativeTime);
    }
    this.timer = setTimeout(() => this.render(), 60000);
  }

  /**
   * Tells if the article is "new". A Short is new on the day of its publication, and a full Article
   * is new for a week. A draft is never new.
   * @param {boolean} today
   * @returns {boolean}
   */
  isNew(today) {
    if (this.draftValue) {
      return false;
    }
    if (this.entryTypeValue === 'Short') {
      return today;
    }
    const published = new Date(this.publishedOn());
    const weekAgo = new Date(this.todayOn());
    weekAgo.setUTCDate(weekAgo.getUTCDate() - 7);
    return published >= weekAgo;
  }

  /**
   * The absolute date, in the words of the server: "Saturday, August 1, 2026".
   * @returns {string}
   */
  absoluteDate() {
    let formatter;
    try {
      formatter = new Intl.DateTimeFormat('en-US', {
        timeZone: this.timeZoneValue || undefined,
        weekday: 'long',
        month: 'long',
        day: 'numeric',
        year: 'numeric',
      });
    } catch {
      formatter = new Intl.DateTimeFormat('en-US', {
        weekday: 'long',
        month: 'long',
        day: 'numeric',
        year: 'numeric',
      });
    }
    return formatter.format(new Date(this.datetimeValue));
  }

  publishedOn() {
    return this.dateInTimeZone(new Date(this.datetimeValue));
  }

  todayOn() {
    return this.dateInTimeZone(new Date());
  }

  /**
   * The YYYY-MM-DD calendar date of `date` in the timezone from the configuration. With no
   * timezone, it uses the local timezone of the viewer.
   * @param {Date} date
   * @returns {string}
   */
  dateInTimeZone(date) {
    return dateFormatter(this.timeZoneValue || '').format(date);
  }
}
