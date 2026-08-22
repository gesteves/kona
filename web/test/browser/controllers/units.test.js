import { describe, expect, it } from 'vitest';
import UnitsController from '../../../source/javascripts/stimulus/controllers/units_controller';
import { mount, stubProperty } from '../helpers';

const MARKUP = `
  <span data-controller="units"
        data-units-imperial-value="26.2 miles"
        data-units-metric-value="42.2 km"></span>
`;

const mountUnits = () => mount('units', UnitsController, MARKUP);

describe('units controller', () => {
  it('renders imperial for en-US', async () => {
    stubProperty(navigator, 'language', 'en-US');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('26.2 miles');
  });

  it('renders imperial for en-LR', async () => {
    // Liberia is the other country with the imperial units that the controller accepts.
    stubProperty(navigator, 'language', 'en-LR');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('26.2 miles');
  });

  it('is case-insensitive about the locale tag', async () => {
    stubProperty(navigator, 'language', 'EN-us');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('26.2 miles');
  });

  it('renders metric for everything else', async () => {
    stubProperty(navigator, 'language', 'es-MX');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('42.2 km');
  });

  it('renders metric for a bare language with no region', async () => {
    // 'en' is not 'en-us', thus an English locale with no region gets the metric units. That is
    // correct: only the region gives the answer.
    stubProperty(navigator, 'language', 'en');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('42.2 km');
  });

  it('lets a ?locale= query param override the browser, for debugging', async () => {
    stubProperty(navigator, 'language', 'es-MX');
    window.history.replaceState({}, '', '/?locale=en-US');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('26.2 miles');
  });

  it('ignores an empty ?locale= and falls back to the browser', async () => {
    stubProperty(navigator, 'language', 'en-US');
    window.history.replaceState({}, '', '/?locale=');

    const { element } = await mountUnits();

    expect(element.textContent).toBe('26.2 miles');
  });
});
