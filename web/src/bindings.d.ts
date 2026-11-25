// The bindings of the Worker. tsconfig.json and tsconfig.test.json both include this file, thus
// the code and the tests read one declaration.

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
