// Hand-written binding types until `wrangler types` is wired into the toolchain.
// Editor support only — wrangler bundles without typechecking.

interface Env {
  // Static Assets binding (wrangler.jsonc `assets.binding`).
  ASSETS: Fetcher;

  // The kona-api origin (fly.io) and the shared bearer its endpoints require (the /widgets/*
  // proxy and the contact-form POST /api/contact).
  KONA_API_URL?: string;
  API_TOKEN?: string;

  // Upstream URL of the site-specific Plausible script; unset disables the proxy,
  // mirroring plausible_installed? on the Ruby side.
  PLAUSIBLE_SCRIPT_URL?: string;
}

interface Fetcher {
  fetch(request: Request): Promise<Response>;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

// Workers expose the zone cache as caches.default (merged into lib.dom's CacheStorage).
interface CacheStorage {
  readonly default: Cache;
}
