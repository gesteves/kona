// Hand-written binding types until `wrangler types` is wired into the toolchain.
// Editor support only — wrangler bundles without typechecking.

interface Env {
  // Static Assets binding (wrangler.jsonc `assets.binding`).
  ASSETS: Fetcher;
  // send_email binding for the contact form.
  EMAIL: SendEmailBinding;

  // The kona-api origin (fly.io) and the shared bearer its widget endpoints require.
  KONA_API_URL?: string;
  API_TOKEN?: string;

  // Upstream URL of the site-specific Plausible script; unset disables the proxy,
  // mirroring plausible_installed? on the Ruby side.
  PLAUSIBLE_SCRIPT_URL?: string;

  // Known Agents tracking. SITE_HOSTNAME gates it to production traffic: preview
  // versions share the production Worker's secrets, so an env flag can't tell them
  // apart — the request hostname can.
  KNOWN_AGENTS_ACCESS_TOKEN?: string;
  SITE_HOSTNAME?: string;

  // Contact form addresses: FROM must be on the Email Routing subdomain, TO must be
  // a verified destination address.
  CONTACT_EMAIL_FROM?: string;
  CONTACT_EMAIL_TO?: string;
}

interface Fetcher {
  fetch(request: Request): Promise<Response>;
}

interface SendEmailBinding {
  send(message: unknown): Promise<void>;
}

declare module 'cloudflare:email' {
  export class EmailMessage {
    constructor(from: string, to: string, raw: string);
  }
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

// Workers expose the zone cache as caches.default (merged into lib.dom's CacheStorage).
interface CacheStorage {
  readonly default: Cache;
}
