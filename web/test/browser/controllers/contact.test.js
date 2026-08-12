import { beforeEach, describe, expect, it, vi } from 'vitest';
import ContactController from '../../../source/javascripts/stimulus/controllers/contact_controller';
import { flushDom, mount } from '../helpers';

// The contact form is progressively enhanced: the markup is a real POST to /api/contact that works
// with no JS at all (native submit → 303 to the Thank-You page). This controller intercepts the
// submit and posts the same fields with `Accept: application/json`, so the api answers 204/422 and
// the result is reported in a toast instead of a navigation.
//
// The encoding is the contract: both paths must send identical bodies, or the api would need two
// code paths for one form.

const SITE_KEY = '0x000000000000000000';

// The fields carry no default values on purpose: `form.reset()` restores DEFAULTS, so a test
// asserting "the form was cleared" against markup with values baked in would pass no matter what
// the controller did. `mountForm` types into them afterwards instead, like a visitor would.
const form = ({ siteKey = '', submitTarget = true } = {}) => `
  <form action="/api/contact" method="post" data-controller="contact"
        data-action="submit->contact#submit"
        ${siteKey ? `data-contact-site-key-value="${siteKey}"` : ''}>
    <input type="text" name="name">
    <input type="email" name="email">
    <textarea name="message"></textarea>
    <input type="text" name="comment">
    <div data-contact-target="turnstile"></div>
    ${submitTarget ? '<wa-button data-contact-target="submit"></wa-button>' : ''}
  </form>
`;

let toast;
let fetchMock;

/** The last message handed to the <wa-toast> stack, with its variant. */
const lastToast = () => {
  const call = toast.create.mock.calls.at(-1);
  return call && { message: call[0], variant: call[1].variant };
};

const mountForm = async (options) => {
  const mounted = await mount('contact', ContactController, form(options));
  document.body.appendChild(toast); // after mount: mount() writes document.body itself
  mounted.element.querySelector('[name="name"]').value = 'Ada';
  mounted.element.querySelector('[name="email"]').value = 'ada@example.com';
  mounted.element.querySelector('[name="message"]').value = 'Hello there';
  return mounted;
};

/** Resolves the memoized Turnstile loader the way the real script's onload callback does. */
const resolveTurnstileScript = async () => {
  window.turnstile = {
    render: vi.fn().mockReturnValue('widget-1'),
    remove: vi.fn(),
    reset: vi.fn(),
  };
  window.__konaTurnstileOnload();
  await flushDom();
};

const submitForm = async () => {
  document
    .querySelector('form')
    .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  await flushDom();
};

beforeEach(() => {
  toast = document.createElement('wa-toast');
  toast.create = vi.fn();
  fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 204 });
  vi.stubGlobal('fetch', fetchMock);
});

describe('submitting', () => {
  it('posts the form fields as urlencoded, asking for JSON', async () => {
    await mountForm();

    await submitForm();

    const [url, options] = fetchMock.mock.calls[0];
    // `form.action` resolves against the document, which is what makes this same-origin and so
    // routed through the Worker proxy rather than straight at the api origin.
    expect(url).toBe('http://localhost:3000/api/contact');
    expect(options.method).toBe('POST');
    expect(options.headers).toEqual({ Accept: 'application/json' });
    // Same encoding as the native no-JS POST — including the empty `comment` honeypot, which the
    // api needs to see in order to decide the submission is human.
    expect(Object.fromEntries(options.body)).toEqual({
      name: 'Ada',
      email: 'ada@example.com',
      message: 'Hello there',
      comment: '',
    });
  });

  it('suppresses the native navigation', async () => {
    await mountForm();
    const event = new Event('submit', { bubbles: true, cancelable: true });

    document.querySelector('form').dispatchEvent(event);
    await flushDom();

    expect(event.defaultPrevented).toBe(true);
  });

  it('clears the form and confirms on success', async () => {
    await mountForm();

    await submitForm();

    expect(lastToast()).toEqual({
      message: 'Thanks! Your message is on its way.',
      variant: 'success',
    });
    expect(document.querySelector('[name="message"]').value).toBe('');
  });

  it('reports a rejected submission without clearing what was typed', async () => {
    // A 422 means the message wasn't sent. Wiping the form would throw away prose the visitor
    // would have to retype. It also surfaces the API's own message: "something went wrong,
    // please try again" would be wrong (nothing went wrong) and unactionable (an identical
    // retry fails identically).
    const apiMessage =
      'Please provide your name, a valid email address, and a message.';
    fetchMock.mockResolvedValue({
      ok: false,
      status: 422,
      json: async () => ({ error: apiMessage }),
    });
    await mountForm();

    await submitForm();

    expect(lastToast()).toEqual({ message: apiMessage, variant: 'danger' });
    expect(document.querySelector('[name="message"]').value).toBe(
      'Hello there'
    );
  });

  it('falls back to the generic message when a 422 carries no usable body', async () => {
    fetchMock.mockResolvedValue({
      ok: false,
      status: 422,
      json: async () => {
        throw new SyntaxError('Unexpected end of JSON input');
      },
    });
    await mountForm();

    await submitForm();

    expect(lastToast().message).toMatch(/something went wrong/i);
    expect(lastToast().variant).toBe('danger');
  });

  it('reports a network failure the same way', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));
    await mountForm();

    await submitForm();

    expect(lastToast().variant).toBe('danger');
  });

  it('stays silent when the submission is aborted by a navigation', async () => {
    const abortError = new Error('aborted');
    abortError.name = 'AbortError';
    fetchMock.mockRejectedValue(abortError);
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});
    await mountForm();

    await submitForm();

    expect(toast.create).not.toHaveBeenCalled();
    expect(consoleError).not.toHaveBeenCalled();
  });

  it('disables the submit button while in flight and re-enables it after', async () => {
    let resolveFetch;
    fetchMock.mockReturnValue(
      new Promise((resolve) => {
        resolveFetch = resolve;
      })
    );
    await mountForm();
    const button = document.querySelector('[data-contact-target="submit"]');

    await submitForm();
    expect(button.loading).toBe(true);
    expect(button.disabled).toBe(true);

    resolveFetch({ ok: true, status: 204 });
    await flushDom();

    expect(button.loading).toBe(false);
    expect(button.disabled).toBe(false);
  });

  it('re-enables the submit button even when the request fails', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));
    await mountForm();

    await submitForm();

    expect(
      document.querySelector('[data-contact-target="submit"]').disabled
    ).toBe(false);
  });

  it('still submits when the button is not wired as a target', async () => {
    await mountForm({ submitTarget: false });

    await submitForm();

    expect(fetchMock).toHaveBeenCalled();
  });

  it('supersedes an in-flight submission rather than sending two', async () => {
    fetchMock.mockReturnValue(new Promise(() => {}));
    await mountForm();

    await submitForm();
    await submitForm();

    expect(fetchMock.mock.calls[0][1].signal.aborted).toBe(true);
    expect(fetchMock.mock.calls[1][1].signal.aborted).toBe(false);
  });
});

describe('Turnstile', () => {
  it('loads nothing when no sitekey is configured', async () => {
    // The sitekey is optional (TURNSTILE_SITE_KEY); with none, the api's check fails open and the
    // other defenses — honeypot, Akismet, length caps, rate limit — carry the form.
    await mountForm();

    expect(document.querySelector('script[src*="turnstile"]')).toBeNull();
  });

  it('injects the api script in explicit-render mode', async () => {
    await mountForm({ siteKey: SITE_KEY });

    const script = document.querySelector('script[src*="turnstile"]');
    // Explicit render, driven from connect/disconnect, is what makes the widget survive Turbo
    // navigation — an auto-scan would only run once, on first page load.
    expect(script.src).toContain('render=explicit');
    expect(script.src).toContain('onload=__konaTurnstileOnload');
    expect(script.async).toBe(true);
  });

  it('renders the widget once the script signals ready', async () => {
    const { element } = await mountForm({ siteKey: SITE_KEY });

    await resolveTurnstileScript();

    expect(window.turnstile.render).toHaveBeenCalledWith(
      element.querySelector('[data-contact-target="turnstile"]'),
      expect.objectContaining({ sitekey: SITE_KEY })
    );
  });

  it('loads the script only once, however many instances connect', async () => {
    // Memoized on `window`, so a Turbo navigation back to the contact page reuses it.
    await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();
    const first = window.__konaTurnstileLoad;

    await mountForm({ siteKey: SITE_KEY });

    expect(window.__konaTurnstileLoad).toBe(first);
    expect(document.querySelectorAll('script[src*="turnstile"]')).toHaveLength(
      1
    );
  });

  it('sends the token with the submission', async () => {
    await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();
    // Explicit render means the token arrives by callback, not in a hidden field.
    window.turnstile.render.mock.calls[0][1].callback('token-abc');

    await submitForm();

    expect(
      Object.fromEntries(fetchMock.mock.calls[0][1].body)[
        'cf-turnstile-response'
      ]
    ).toBe('token-abc');
  });

  it('drops the token when Turnstile reports an error or an expiry', async () => {
    await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();
    const options = window.turnstile.render.mock.calls[0][1];
    options.callback('token-abc');
    options['expired-callback']();

    await submitForm();

    // Tokens are single-use and expire after 300s; sending a spent one would just fail the
    // server-side check.
    expect(fetchMock.mock.calls[0][1].body.has('cf-turnstile-response')).toBe(
      false
    );
  });

  it('resets the widget after a successful submission', async () => {
    await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();
    window.turnstile.render.mock.calls[0][1].callback('token-abc');

    await submitForm();

    expect(window.turnstile.reset).toHaveBeenCalledWith('widget-1');
  });

  it('resets the widget after a failure too, so a retry gets a fresh token', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    fetchMock.mockResolvedValue({ ok: false, status: 422 });
    await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();

    await submitForm();

    expect(window.turnstile.reset).toHaveBeenCalled();
  });

  it('tears the widget down when the element goes away', async () => {
    const { element } = await mountForm({ siteKey: SITE_KEY });
    await resolveTurnstileScript();

    element.remove();
    await flushDom();

    expect(window.turnstile.remove).toHaveBeenCalledWith('widget-1');
  });

  it('logs and carries on when the script fails to load', async () => {
    // The form still works — this is the enhancement layer, not the gate.
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});
    await mountForm({ siteKey: SITE_KEY });

    document
      .querySelector('script[src*="turnstile"]')
      .dispatchEvent(new Event('error'));
    await flushDom();

    expect(consoleError).toHaveBeenCalledWith(
      'Turnstile failed to load:',
      expect.anything()
    );
  });
});
