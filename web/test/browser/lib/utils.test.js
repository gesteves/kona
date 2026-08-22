import { describe, expect, it, vi } from 'vitest';
import {
  absoluteUrl,
  canonicalUrl,
  replaceElement,
  sendNotification,
} from '../../../source/javascripts/stimulus/lib/utils';

describe('sendNotification', () => {
  it('does nothing when the toast stack is absent', () => {
    expect(() => sendNotification('hello')).not.toThrow();
  });

  it('does nothing when the element exists but has not upgraded yet', () => {
    // <wa-toast> is a custom element. Before its module loads, it is an unknown element that does
    // nothing and that has no create(). The code tests the method and not the element, thus a toast
    // early in the life of the page does not raise.
    document.body.innerHTML = '<wa-toast></wa-toast>';
    expect(() => sendNotification('hello')).not.toThrow();
  });

  it('creates a success toast with the shared duration', () => {
    document.body.innerHTML = '<wa-toast></wa-toast>';
    const create = vi.fn();
    document.querySelector('wa-toast').create = create;

    sendNotification('Saved');

    expect(create).toHaveBeenCalledWith('Saved', {
      variant: 'success',
      duration: 3000,
    });
  });

  it('maps any non-success status to the danger variant', () => {
    document.body.innerHTML = '<wa-toast></wa-toast>';
    const create = vi.fn();
    document.querySelector('wa-toast').create = create;

    // A caller gives 'error', and the Web Awesome variant is 'danger'. This change is the purpose
    // of the code.
    sendNotification('Nope', 'error');

    expect(create.mock.calls[0][1].variant).toBe('danger');
  });
});

describe('replaceElement', () => {
  it('swaps the element for the parsed markup', () => {
    document.body.innerHTML = '<div id="old">old</div>';
    const element = document.getElementById('old');

    replaceElement('<p id="new">new</p>', element);

    expect(document.getElementById('old')).toBeNull();
    expect(document.getElementById('new').textContent).toBe('new');
  });

  it('inserts every root node, not just the first', () => {
    document.body.innerHTML = '<div id="old"></div>';

    replaceElement('<p>one</p><p>two</p>', document.getElementById('old'));

    expect(document.body.querySelectorAll('p')).toHaveLength(2);
  });

  it('removes the element when given empty markup', () => {
    document.body.innerHTML = '<div id="old"></div>';

    replaceElement('', document.getElementById('old'));

    expect(document.getElementById('old')).toBeNull();
  });
});

describe('canonicalUrl', () => {
  it('prefers the canonical link', () => {
    document.head.innerHTML =
      '<link rel="canonical" href="https://example.com/canonical">';

    expect(canonicalUrl()).toBe('https://example.com/canonical');
  });

  it('resolves a relative canonical href against the document', () => {
    document.head.innerHTML = '<link rel="canonical" href="/relative">';

    expect(canonicalUrl()).toBe('http://localhost:3000/relative');
  });

  it('falls back to the current location when there is no canonical link', () => {
    expect(canonicalUrl()).toBe(window.location.href);
  });
});

describe('absoluteUrl', () => {
  it('returns the current page for a missing href', () => {
    expect(absoluteUrl(null)).toBe(window.location.href);
    expect(absoluteUrl('')).toBe(window.location.href);
  });

  it('anchors a fragment to the current path, dropping any query string', () => {
    window.history.replaceState({}, '', '/posts/hello?utm_source=x');

    // This uses the origin, the pathname, and the hash, on purpose: a permalink from an article must
    // not have the tracking parameters of the reader.
    expect(absoluteUrl('#comments')).toBe(
      'http://localhost:3000/posts/hello#comments'
    );
  });

  it('leaves a protocol-relative URL alone', () => {
    expect(absoluteUrl('//cdn.example.com/a.png')).toBe(
      '//cdn.example.com/a.png'
    );
  });

  it('resolves a root-relative href against the origin', () => {
    expect(absoluteUrl('/2026/01/01/hello')).toBe(
      'http://localhost:3000/2026/01/01/hello'
    );
  });

  it('leaves an absolute URL alone', () => {
    expect(absoluteUrl('https://example.com/x')).toBe('https://example.com/x');
  });
});
