import { vi } from 'vitest';

// Shared harness for the jsdom suite: mounting a Stimulus controller on real markup, flushing
// Stimulus's MutationObserver, and stubbing the read-only `navigator` properties these controllers
// feature-detect.

const mountedApplications = [];
const stubbedProperties = [];

/**
 * Mounts one controller on real markup and starts a Stimulus application around it.
 *
 * The HTML is written to the document BEFORE the application starts, which makes the initial
 * connect synchronous: `Application#start` awaits domReady and then runs a full `ElementObserver`
 * refresh in the same turn, so by the time this resolves `connect()` has already run. Elements
 * added *after* mounting (a swapped-in fragment, say) arrive via MutationObserver instead — await
 * `flushDom()` for those.
 *
 * @param {string} identifier The Stimulus identifier, e.g. 'live-update'.
 * @param {Function} controllerClass The controller class under test.
 * @param {string} html Markup for document.body. Must contain a matching data-controller element.
 * @param {Function} [prepare] Runs on the parsed document after the markup lands but before the
 *   application starts — the only window in which to set up state `connect()` will read (an
 *   <img>'s `complete`, say), since connect runs during start.
 * @returns {Promise<{application: Object, element: Element, controller: Object}>}
 */
export async function mount(identifier, controllerClass, html, prepare) {
  // Imported here rather than at module scope so that a suite calling vi.resetModules() gets the
  // SAME @hotwired/stimulus instance as the freshly-imported controller under test. A static
  // import would pin the pre-reset copy, and the two module graphs would quietly disagree.
  const { Application } = await import('@hotwired/stimulus');

  document.body.innerHTML = html;
  prepare?.(document);

  const application = new Application(document.documentElement);
  // Stimulus logs uncaught controller errors through this; let them fail the test instead.
  application.handleError = (error) => {
    throw error;
  };
  application.register(identifier, controllerClass);
  await application.start();
  mountedApplications.push(application);

  const element = document.querySelector(`[data-controller~="${identifier}"]`);
  return {
    application,
    element,
    controller: application.getControllerForElementAndIdentifier(
      element,
      identifier
    ),
  };
}

/**
 * Yields long enough for Stimulus to process DOM mutations. Its ElementObserver runs off a
 * MutationObserver, whose callback is a microtask, so awaiting a few turns is sufficient — and
 * unlike a `setTimeout`, it still works under fake timers.
 * @returns {Promise<void>}
 */
export async function flushDom() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

/**
 * Defines a property that jsdom exposes as a read-only getter (`navigator.clipboard`,
 * `navigator.share`, `navigator.language`), which `vi.stubGlobal` can't touch. Restored by
 * `restoreStubbedProperties()` in the global afterEach.
 * @param {Object} object The host object, e.g. `navigator`.
 * @param {string} property The property name.
 * @param {*} value The value to expose.
 */
export function stubProperty(object, property, value) {
  const original = Object.getOwnPropertyDescriptor(object, property);
  stubbedProperties.push({ object, property, original });
  Object.defineProperty(object, property, {
    value,
    configurable: true,
    writable: true,
  });
}

/** Undoes every `stubProperty` call. */
export function restoreStubbedProperties() {
  while (stubbedProperties.length > 0) {
    const { object, property, original } = stubbedProperties.pop();
    if (original) {
      Object.defineProperty(object, property, original);
    } else {
      delete object[property];
    }
  }
}

/** Stops every application `mount()` started, disconnecting their controllers. */
export function stopMountedApplications() {
  while (mountedApplications.length > 0) {
    mountedApplications.pop().stop();
  }
}

/**
 * Installs a `window.plausible` spy matching the real queue stub's call signature.
 * @returns {Function} The spy, so tests can assert on `mock.calls`.
 */
export function stubPlausible() {
  const plausible = vi.fn((_event, options) => options?.callback?.());
  window.plausible = plausible;
  return plausible;
}

/**
 * A `fetch` stub returning one HTML fragment, for the live-update controller.
 * @param {string} body The response body.
 * @param {number} status The HTTP status.
 * @returns {Function} A vi.fn() suitable for `vi.stubGlobal('fetch', …)`.
 */
export function stubFetchReturning(body, status = 200) {
  return vi.fn(async () => new Response(body, { status }));
}
