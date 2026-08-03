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

    // The server bakes in the build-time year as a no-JS fallback; the point of the controller is
    // that a site built in 2026 still shows the right copyright range in 2031 without a rebuild.
    const { element } = await mount(
      'current-year',
      CurrentYearController,
      '<span data-controller="current-year">2026</span>'
    );

    expect(element.textContent).toBe('2031');
  });
});
