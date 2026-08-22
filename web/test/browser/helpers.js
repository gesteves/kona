import { vi } from 'vitest';

// The shared code for the jsdom suite. It puts a Stimulus controller on real markup, it makes the
// Stimulus MutationObserver run, and it replaces the read-only `navigator` properties that these
// controllers look for.

const mountedApplications = [];
const stubbedProperties = [];

/**
 * Puts one controller on real markup and starts a Stimulus application around it.
 *
 * The code writes the HTML into the document BEFORE the application starts, thus the first connect
 * is synchronous. `Application#start` waits for domReady and then does a full `ElementObserver`
 * refresh in the same turn. Thus `connect()` already ran when this promise resolves. An element
 * that the code adds *after* the mount, for example a fragment that replaces another element,
 * comes through the MutationObserver. Wait for `flushDom()` for such an element.
 *
 * @param {string} identifier The Stimulus identifier, for example 'live-update'.
 * @param {Function} controllerClass The controller class for the test.
 * @param {string} html The markup for document.body. It must contain a data-controller element
 *   that matches.
 * @param {Function} [prepare] This runs on the parsed document after the markup arrives and before
 *   the application starts. It is the only time to set the state that `connect()` reads, for
 *   example the `complete` value of an <img>, because connect runs during the start.
 * @returns {Promise<{application: Object, element: Element, controller: Object}>}
 */
export async function mount(identifier, controllerClass, html, prepare) {
  // The import is here and not at the module level. Thus a suite that calls vi.resetModules()
  // gets the SAME @hotwired/stimulus instance as the new controller for the test. A static import
  // would keep the copy from before the reset, and the two module graphs would not agree.
  const { Application } = await import('@hotwired/stimulus');

  document.body.innerHTML = html;
  prepare?.(document);

  const application = new Application(document.documentElement);
  // Stimulus writes each controller error that nothing caught through this. Make them fail the
  // test instead.
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
 * Waits long enough for Stimulus to read the DOM changes. Its ElementObserver uses a
 * MutationObserver, and the callback of that observer is a microtask. Thus a wait of a few turns is
 * sufficient. A `setTimeout` is different: this method also works with fake timers.
 * @returns {Promise<void>}
 */
export async function flushDom() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

/**
 * Defines a property that jsdom gives as a read-only getter (`navigator.clipboard`,
 * `navigator.share`, and `navigator.language`), which `vi.stubGlobal` cannot change.
 * `restoreStubbedProperties()` in the global afterEach puts the property back.
 * @param {Object} object The host object, for example `navigator`.
 * @param {string} property The name of the property.
 * @param {*} value The value to give.
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

/** Removes the result of each `stubProperty` call. */
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

/** Stops each application that `mount()` started, and disconnects their controllers. */
export function stopMountedApplications() {
  while (mountedApplications.length > 0) {
    mountedApplications.pop().stop();
  }
}

/**
 * Adds a `window.plausible` spy with the same parameters as the real queue stub.
 * @returns {Function} The spy, thus a test can read `mock.calls`.
 */
export function stubPlausible() {
  const plausible = vi.fn((_event, options) => options?.callback?.());
  window.plausible = plausible;
  return plausible;
}

/**
 * A `fetch` stub that returns one HTML fragment, for the live-update controller.
 * @param {string} body The response body.
 * @param {number} status The HTTP status.
 * @returns {Function} A vi.fn() for `vi.stubGlobal('fetch', …)`.
 */
export function stubFetchReturning(body, status = 200) {
  return vi.fn(async () => new Response(body, { status }));
}
