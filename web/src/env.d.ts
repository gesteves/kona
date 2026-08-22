// The binding types, which a person writes, until the tools use `wrangler types`.
// These help the editor only: wrangler makes the bundle and checks no type.

interface Env {
  // The Static Assets binding, from `assets.binding` in wrangler.jsonc.
  ASSETS: Fetcher;

  // The kona-api origin on fly.io, and the shared bearer token that its endpoints need: the
  // /widgets/* proxy and the POST /api/contact of the contact form.
  KONA_API_URL?: string;
  API_TOKEN?: string;

  // The upstream URL of the Plausible script of this site. With no value, the proxy does nothing,
  // as plausible_installed? does in the Ruby code.
  PLAUSIBLE_SCRIPT_URL?: string;
}

interface Fetcher {
  fetch(request: Request): Promise<Response>;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

// A Worker gives the zone cache as caches.default. It is part of the CacheStorage of lib.dom.
interface CacheStorage {
  readonly default: Cache;
}

// The HTML parser of Workers, which reads a stream. src/og.ts uses it to get one <meta> from a page
// and it holds no copy of the page. This file declares only the parts that this app calls.
// ⚠️ getAttribute returns the attribute as the source writes it. HTMLRewriter does not decode a
// character reference, and that is why og.ts also calls decodeEntities on the result.
interface HTMLRewriterElement {
  getAttribute(name: string): string | null;
}

interface HTMLRewriterElementHandlers {
  element?(element: HTMLRewriterElement): void;
}

declare class HTMLRewriter {
  on(selector: string, handlers: HTMLRewriterElementHandlers): HTMLRewriter;
  transform(response: Response): Response;
}

// The declarations of the binary modules (.wasm, .ttf, and .png) are in src/assets.d.ts, and
// tsconfig.test.json also includes that file. Refer to the note there.
