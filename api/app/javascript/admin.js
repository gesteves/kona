// esbuild entrypoint for the owner-facing admin UI. Bundles the Web Awesome stylesheet, our Sass,
// Turbo, the Web Awesome components the layouts use, and the Stimulus application into
// app/assets/builds/admin.js + admin.css, which Propshaft then fingerprints. Build config, and why
// it's a file rather than CLI flags, in esbuild.config.mjs.

// ⚠️ Order is load-bearing: Web Awesome puts every rule in `@layer wa-native, wa-base, …`, and
// unlayered rules outrank layered ones whatever their specificity — so our styles win on cascade
// origin alone, but only because esbuild concatenates them *after* webawesome.css.
import "@web.awesome.me/webawesome-pro/dist/styles/webawesome.css";
import "./styles/admin.scss";

// Side-effect import: Turbo self-installs on load and nothing here references its exports.
import "@hotwired/turbo";
import { Application } from "@hotwired/stimulus";

// The full stylesheet above is deliberate — `layers.css` is what defines `.wa-mobile-only` and the
// rule hiding `[data-toggle-nav]` on desktop, and `utilities/fouce.css` is what provides
// `.wa-cloak`. Cherry-picking the theme (as web/ does) would silently drop both.
// <wa-page> statically imports button, drawer, and icon, so those arrive with it.
import "@web.awesome.me/webawesome-pro/dist/components/page/page.js";
import "@web.awesome.me/webawesome-pro/dist/components/card/card.js";
import "@web.awesome.me/webawesome-pro/dist/components/callout/callout.js";
import "@web.awesome.me/webawesome-pro/dist/components/badge/badge.js";

import FlashController from "./controllers/flash_controller";

// window.Stimulus stays exposed for console debugging, but registration goes through the local
// binding — the bare global is invisible to static analysis.
const application = Application.start();
window.Stimulus = application;
application.register("flash", FlashController);
