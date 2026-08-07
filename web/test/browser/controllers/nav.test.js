import { describe, expect, it, vi } from 'vitest';
import NavController from '../../../source/javascripts/stimulus/controllers/nav_controller';
import { mount } from '../helpers';

// The open/closed state lives as a class on <body> (the menu is full-screen on mobile), so the
// controller's job is to keep that class and the button's ARIA state in lockstep.

const MARKUP = `
  <nav data-controller="nav" data-nav-open-class="nav-open">
    <button data-nav-target="button"
            data-action="nav#toggleNav search:close@document->nav#closeNav"
            aria-expanded="false"
            aria-label="Open menu">Menu</button>
  </nav>
`;

const mountNav = () => mount('nav', NavController, MARKUP);
const button = () => document.querySelector('[data-nav-target="button"]');
const isOpen = () => document.body.classList.contains('nav-open');

describe('nav controller', () => {
  it('opens on the first toggle and updates the button state', async () => {
    const { element } = await mountNav();

    element.querySelector('button').click();

    expect(isOpen()).toBe(true);
    expect(button().getAttribute('aria-expanded')).toBe('true');
    expect(button().getAttribute('aria-label')).toBe('Close menu');
  });

  it('closes again on a second toggle', async () => {
    const { element } = await mountNav();

    element.querySelector('button').click();
    element.querySelector('button').click();

    expect(isOpen()).toBe(false);
    expect(button().getAttribute('aria-expanded')).toBe('false');
    expect(button().getAttribute('aria-label')).toBe('Open menu');
  });

  it('suppresses the default action so the trigger link does not navigate', async () => {
    const { element } = await mountNav();
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    element.querySelector('button').dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
  });

  it('closes when search opens, so dismissing search returns to the page', async () => {
    // On mobile the Search item sits inside the open hamburger menu; search#open dispatches
    // `search:close` on the document so the menu isn't left standing behind the modal.
    const { element } = await mountNav();
    element.querySelector('button').click();

    document.dispatchEvent(new CustomEvent('search:close'));

    expect(isOpen()).toBe(false);
    expect(button().getAttribute('aria-expanded')).toBe('false');
  });

  it('is a no-op when closing an already-closed menu', async () => {
    await mountNav();

    document.dispatchEvent(new CustomEvent('search:close'));

    expect(isOpen()).toBe(false);
  });

  // The open menu is a full-viewport overlay. Without inert, the reader can tab straight through
  // it into page content they can't see.
  it('makes the page behind the menu inert while it is open', async () => {
    const { element } = await mountNav();
    const main = document.createElement('main');
    main.id = 'main-content';
    document.body.appendChild(main);

    element.querySelector('button').click();
    expect(main.inert).toBe(true);

    element.querySelector('button').click();
    expect(main.inert).toBe(false);
  });

  // The open menu fixes <body>, which collapses the scroll height — so the offset has to be
  // stashed and put back, or closing the menu silently returns the reader to the top.
  it('restores the scroll position when the menu closes', async () => {
    const { element } = await mountNav();
    window.scrollY = 1200;
    const scrollTo = vi.fn();
    window.scrollTo = scrollTo;

    element.querySelector('button').click();
    expect(document.body.style.top).toBe('-1200px');

    element.querySelector('button').click();
    expect(document.body.style.top).toBe('');
    expect(scrollTo).toHaveBeenCalledWith(0, 1200);
  });

  it('does not scroll when closing a menu that was never open', async () => {
    await mountNav();
    const scrollTo = vi.fn();
    window.scrollTo = scrollTo;

    document.dispatchEvent(new CustomEvent('search:close'));

    expect(scrollTo).not.toHaveBeenCalled();
  });

  it('uses custom ARIA labels when supplied', async () => {
    const { element } = await mount(
      'nav',
      NavController,
      `<nav data-controller="nav" data-nav-open-class="nav-open"
            data-nav-open-aria-label-value="Abrir menú"
            data-nav-close-aria-label-value="Cerrar menú">
         <button data-nav-target="button" data-action="nav#toggleNav"></button>
       </nav>`
    );

    element.querySelector('button').click();
    expect(button().getAttribute('aria-label')).toBe('Cerrar menú');

    element.querySelector('button').click();
    expect(button().getAttribute('aria-label')).toBe('Abrir menú');
  });
});
