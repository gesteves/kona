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
// The Location page's rule between the address search and the race shortcuts.
import "@web.awesome.me/webawesome-pro/dist/components/divider/divider.js";
import "@web.awesome.me/webawesome-pro/dist/components/badge/badge.js";
// The Contact page's spam cards. wa-details and wa-dialog render their own chevron and close
// icons through <wa-icon library="system">, which resolves to inline data URIs bundled with the
// component — so the "don't use <wa-icon>" rule doesn't reach them. Ours still go via icon_svg.
import "@web.awesome.me/webawesome-pro/dist/components/details/details.js";
import "@web.awesome.me/webawesome-pro/dist/components/dialog/dialog.js";
import "@web.awesome.me/webawesome-pro/dist/components/relative-time/relative-time.js";
// Form controls, for the Course maps page's upload and render settings and the Location page's
// coordinates. Every other form in the admin is action-only; these are form-associated, so they
// submit and appear in FormData exactly like native controls.
import "@web.awesome.me/webawesome-pro/dist/components/file-input/file-input.js";
import "@web.awesome.me/webawesome-pro/dist/components/input/input.js";
import "@web.awesome.me/webawesome-pro/dist/components/number-input/number-input.js";
import "@web.awesome.me/webawesome-pro/dist/components/slider/slider.js";
import "@web.awesome.me/webawesome-pro/dist/components/color-picker/color-picker.js";
import "@web.awesome.me/webawesome-pro/dist/components/select/select.js";
import "@web.awesome.me/webawesome-pro/dist/components/option/option.js";
import "@web.awesome.me/webawesome-pro/dist/components/switch/switch.js";
import "@web.awesome.me/webawesome-pro/dist/components/spinner/spinner.js";

import FlashController from "./controllers/flash_controller";
import DialogController from "./controllers/dialog_controller";
import LocationMapController from "./controllers/location_map_controller";
import MapStatusController from "./controllers/map_status_controller";
import MapPreviewController from "./controllers/map_preview_controller";
import LinkedSidesController from "./controllers/linked_sides_controller";

// window.Stimulus stays exposed for console debugging, but registration goes through the local
// binding — the bare global is invisible to static analysis.
const application = Application.start();
window.Stimulus = application;
application.register("flash", FlashController);
application.register("dialog", DialogController);
application.register("location-map", LocationMapController);
application.register("map-status", MapStatusController);
application.register("map-preview", MapPreviewController);
application.register("linked-sides", LinkedSidesController);
