import { afterEach, describe, expect, it, vi } from 'vitest';
import CurrentYearController from '../../../source/javascripts/stimulus/controllers/current_year_controller';
import { mount } from '../helpers';

afterEach(() => {
  vi.useRealTimers();
});

describe('current-year controller', () => {
  it('overwrites the server-rendered year with the current one', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2031-03-04T12:00:00Z'));

    // The server writes the year of the build, for a browser with no JavaScript. The purpose of the
    // controller is that a site from a build in 2026 still shows the correct range of copyright
    // years in 2031, with no new build.
    const { element } = await mount(
      'current-year',
      CurrentYearController,
      '<span data-controller="current-year">2026</span>'
    );

    expect(element.textContent).toBe('2031');
  });
});
