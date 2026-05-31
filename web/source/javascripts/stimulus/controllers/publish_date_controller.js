import { Controller } from '@hotwired/stimulus';
import { formatDistanceToNow } from 'date-fns';

/**
 * Renders the publish-date-dependent parts of an article's meta line on the client, so they stay
 * correct without a rebuild: the "New" badge, the clock-vs-calendar icon, and the relative-vs-
 * absolute permalink timestamp.
 *
 * The server renders every state — the calendar icon and the absolute date are visible by default
 * (the no-JS fallback), while the clock icon and the "New" badge are present but hidden — and this
 * controller reveals the right ones based on the current date reckoned in the site's timezone.
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
    if (this.hasTimestampTarget) {
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
   * Shows a live-updating relative time for recent articles, or the server-rendered absolute date
   * otherwise. While relative, re-renders every minute — which also flips the display to the
   * absolute date once the article is no longer published "today".
   * @param {boolean} relative
   */
  renderTimestamp(relative) {
    if (!relative) {
      this.timestampTarget.textContent = this.absoluteTimestamp;
      return;
    }
    this.timestampTarget.textContent = formatDistanceToNow(
      new Date(this.datetimeValue),
      {
        addSuffix: true,
        includeSeconds: true,
      }
    );
    this.timer = setTimeout(() => this.render(), 60000);
  }

  /**
   * Whether the article is "new": a Short is new the day it's published, a full Article for a week.
   * Drafts are never new.
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

  publishedOn() {
    return this.dateInTimeZone(new Date(this.datetimeValue));
  }

  todayOn() {
    return this.dateInTimeZone(new Date());
  }

  /**
   * The YYYY-MM-DD calendar date of `date` in the configured timezone (falling back to the
   * viewer's local timezone when none is set).
   * @param {Date} date
   * @returns {string}
   */
  dateInTimeZone(date) {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: this.timeZoneValue || undefined,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(date);
  }
}
