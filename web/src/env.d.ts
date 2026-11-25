// The Worker globals, which a person writes, until the tools use `wrangler types`. These are for
// tsc (`npm run check`) and the editor: wrangler makes the bundle and checks no type.
// ⚠️ tsconfig.test.json does NOT include this file: the tests get these globals from
// @cloudflare/workers-types, and the two would conflict. `Env` is in src/bindings.d.ts for that
// reason.

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

// The HTML parser of Workers, which reads a stream. src/og.ts uses it to read two <meta> tags and
// the end of <head>, and it holds no copy of the page. This file declares only the parts that
// this app calls. getAttribute does not decode an entity: refer to decodeEntities in og-meta.ts.
interface HTMLRewriterElement {
  getAttribute(name: string): string | null;
  onEndTag(handler: (endTag: unknown) => void | Promise<void>): void;
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
