import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import PublishDateController from '../../../source/javascripts/stimulus/controllers/publish_date_controller';
import { flushDom, mount } from '../helpers';

// This renders in the browser the parts of the meta line of an article that depend on the publish
// date. Thus a site from some weeks ago still shows the correct content: the "New" badge, the clock
// icon or the calendar icon, and a relative time or an absolute time.
//
// The server renders EACH state: the calendar icon and the absolute date are visible, which is the
// result with no JavaScript, and the clock and the badge are in the page but hidden. The controller
// then shows the correct ones. Thus each test below checks which of four elements from the server
// is visible.
//
// The code uses the timezone of the SITE for each date, and not the timezone of the viewer:
// "published today" must have the same meaning for a reader in Tokyo and for the author.
const TIME_ZONE = 'America/New_York';
const ABSOLUTE = 'August 1, 2026';

const markup = ({ datetime, entryType = 'Article', draft = false }) => `
  <div data-controller="publish-date"
       ${datetime ? `data-publish-date-datetime-value="${datetime}"` : ''}
       data-publish-date-time-zone-value="${TIME_ZONE}"
       data-publish-date-entry-type-value="${entryType}"
       data-publish-date-draft-value="${draft}">
    <span data-publish-date-target="badge" hidden>New</span>
    <span data-publish-date-target="clock" hidden>clock</span>
    <span data-publish-date-target="calendar">calendar</span>
    <span data-publish-date-target="timestamp">${ABSOLUTE}</span>
  </div>
`;

const target = (name) =>
  document.querySelector(`[data-publish-date-target="${name}"]`);
const visible = (name) => !target(name).hidden;

const mountAt = (nowIso, options) => {
  vi.setSystemTime(new Date(nowIso));
  return mount('publish-date', PublishDateController, markup(options));
};

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('an article published today', () => {
  // 2026-08-01 12:00 EDT, and the reader opens the page at 2026-08-01 18:00 EDT.
  const published = '2026-08-01T16:00:00Z';
  const now = '2026-08-01T22:00:00Z';

  it('shows the New badge', async () => {
    await mountAt(now, { datetime: published });

    expect(visible('badge')).toBe(true);
  });

  it('shows the clock icon instead of the calendar', async () => {
    await mountAt(now, { datetime: published });

    expect(visible('clock')).toBe(true);
    expect(visible('calendar')).toBe(false);
  });

  it('replaces the absolute date with a self-syncing relative time', async () => {
    await mountAt(now, { datetime: published });

    const relativeTime = target('timestamp').querySelector('wa-relative-time');
    expect(relativeTime.getAttribute('date')).toBe(
      new Date(published).toISOString()
    );
    expect(relativeTime.hasAttribute('sync')).toBe(true);
  });
});

describe('the New badge window', () => {
  it('stays on for a full Article a few days old', async () => {
    // Note the difference: the article is still "new", but it is no longer from "today". Thus the
    // badge appears and the timestamp is already the absolute date. These are two questions.
    await mountAt('2026-08-04T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });

    expect(visible('badge')).toBe(true);
    expect(visible('calendar')).toBe(true);
    expect(target('timestamp').textContent).toBe(ABSOLUTE);
  });

  it('is still on exactly seven days later', async () => {
    await mountAt('2026-08-08T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });

    expect(visible('badge')).toBe(true);
  });

  it('is off eight days later', async () => {
    await mountAt('2026-08-09T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });

    expect(visible('badge')).toBe(false);
  });

  it('lasts only the publication day for a Short', async () => {
    await mountAt('2026-08-02T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
      entryType: 'Short',
    });

    expect(visible('badge')).toBe(false);
  });

  it('covers the publication day itself for a Short', async () => {
    await mountAt('2026-08-01T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
      entryType: 'Short',
    });

    expect(visible('badge')).toBe(true);
  });

  it('never marks a draft as new', async () => {
    await mountAt('2026-08-01T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
      draft: true,
    });

    expect(visible('badge')).toBe(false);
  });

  it('still treats a draft as recent, so it reads as a live preview', async () => {
    // A draft always has the clock and a relative time, at each age, because you look at something
    // that you still work on.
    await mountAt('2026-09-01T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
      draft: true,
    });

    expect(visible('clock')).toBe(true);
    expect(visible('calendar')).toBe(false);
    expect(
      target('timestamp').querySelector('wa-relative-time')
    ).not.toBeNull();
  });
});

describe('timezone handling', () => {
  it('reckons the date in the site timezone, not UTC', async () => {
    // 2026-08-02T02:00Z is the 2nd day in UTC, but it is 22:00 on the 1st day in New York, and
    // "today" must mean the today of the site owner. The reader opens the page at
    // 2026-08-01 23:00 EDT.
    await mountAt('2026-08-02T03:00:00Z', {
      datetime: '2026-08-02T02:00:00Z',
    });

    expect(visible('clock')).toBe(true);
    expect(visible('badge')).toBe(true);
  });

  it('falls back to the viewer’s timezone when none is configured', async () => {
    vi.setSystemTime(new Date('2026-08-01T22:00:00Z'));

    await mount(
      'publish-date',
      PublishDateController,
      `<div data-controller="publish-date"
            data-publish-date-datetime-value="2026-08-01T22:00:00Z"
            data-publish-date-entry-type-value="Article">
         <span data-publish-date-target="clock" hidden></span>
         <span data-publish-date-target="calendar"></span>
       </div>`
    );

    expect(visible('clock')).toBe(true);
  });
});

describe('re-rendering', () => {
  it('flips to the absolute date once the article stops being today', async () => {
    // The relative time updates itself, but no code in it knows that the article is near the end of
    // "today". That is the purpose of the timer for each minute. The mount occurs at
    // 23:59:30 EDT.
    await mountAt('2026-08-02T03:59:30Z', {
      datetime: '2026-08-01T16:00:00Z',
    });
    expect(visible('clock')).toBe(true);

    vi.advanceTimersByTime(60_000); // → 00:00:30 EDT, the next day
    await flushDom();

    expect(visible('clock')).toBe(false);
    expect(visible('calendar')).toBe(true);
    expect(target('timestamp').textContent).toBe(ABSOLUTE);
    expect(visible('badge')).toBe(true); // still inside the seven-day window
  });

  it('reuses the existing relative-time element rather than recreating it each minute', async () => {
    // A new element would start its own updates again and the text would move.
    await mountAt('2026-08-01T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });
    const first = target('timestamp').querySelector('wa-relative-time');

    vi.advanceTimersByTime(60_000);
    await flushDom();

    expect(target('timestamp').querySelector('wa-relative-time')).toBe(first);
  });

  it('stops the timer when the element goes away', async () => {
    const { controller, element } = await mountAt('2026-08-01T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });
    const render = vi.spyOn(controller, 'render');

    element.remove();
    await flushDom();
    vi.advanceTimersByTime(300_000);

    expect(render).not.toHaveBeenCalled();
  });

  it('leaves no timer running once the date is no longer relative', async () => {
    const { controller } = await mountAt('2026-08-09T22:00:00Z', {
      datetime: '2026-08-01T16:00:00Z',
    });
    const render = vi.spyOn(controller, 'render');

    vi.advanceTimersByTime(300_000);

    expect(render).not.toHaveBeenCalled();
  });
});

describe('without a datetime', () => {
  it('leaves the server-rendered fallback exactly as it is', async () => {
    // With no datetime there is no value to calculate from. Thus the render with no JavaScript
    // stays: the calendar icon, the absolute date, and no badge.
    await mountAt('2026-08-01T22:00:00Z', { datetime: null });

    expect(visible('badge')).toBe(false);
    expect(visible('clock')).toBe(false);
    expect(visible('calendar')).toBe(true);
    expect(target('timestamp').textContent).toBe(ABSOLUTE);
  });
});
