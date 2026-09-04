// The esbuild entry point for the admin UI of the owner. It puts the Web Awesome stylesheet, our
// Sass, Turbo, the Web Awesome components that the layouts use, and the Stimulus application into
// app/assets/builds/admin.js and admin.css. Propshaft then adds a fingerprint to each name. The
// build configuration is in esbuild.config.mjs, with the reason that it is a file and not a set of
// CLI flags.

// ⚠️ The order is important: Web Awesome puts each rule in `@layer wa-native, wa-base, …`, and an
// unlayered rule wins over a rule in a layer, at each specificity. Thus our styles win because of
// the cascade origin, but only because esbuild puts them *after* webawesome.css.
import "@web.awesome.me/webawesome-pro/dist/styles/webawesome.css";
import "./styles/admin.scss";

// This import is for its result only: Turbo installs itself at the load and no code here uses its
// exports.
import "@hotwired/turbo";
import { Application } from "@hotwired/stimulus";

// The full stylesheet above is correct, on purpose. `layers.css` defines `.wa-mobile-only` and the
// rule that hides `[data-toggle-nav]` on the desktop, and `utilities/fouce.css` gives `.wa-cloak`.
// A selection of the theme only, as web/ does, would remove both with no message.
// <wa-page> imports button, drawer, and icon, thus those three come with it.
import "@web.awesome.me/webawesome-pro/dist/components/page/page.js";
import "@web.awesome.me/webawesome-pro/dist/components/card/card.js";
import "@web.awesome.me/webawesome-pro/dist/components/callout/callout.js";
// The line on the Location page between the address search and the race shortcuts.
import "@web.awesome.me/webawesome-pro/dist/components/divider/divider.js";
import "@web.awesome.me/webawesome-pro/dist/components/badge/badge.js";
// The spam cards of the Contact page. wa-details and wa-dialog render their own chevron icon and
// close icon with <wa-icon library="system">, which gives inline data URIs from the component. Thus
// the "do not use <wa-icon>" rule does not apply to them. Our icons still come from icon_svg.
import "@web.awesome.me/webawesome-pro/dist/components/details/details.js";
import "@web.awesome.me/webawesome-pro/dist/components/dialog/dialog.js";
import "@web.awesome.me/webawesome-pro/dist/components/relative-time/relative-time.js";
// The form controls, for the upload and the render settings of the Course maps page and for the
// coordinates of the Location page. Each other form in the admin has an action only. These controls
// are part of their form, thus they submit and appear in FormData as a native control does.
import "@web.awesome.me/webawesome-pro/dist/components/file-input/file-input.js";
import "@web.awesome.me/webawesome-pro/dist/components/input/input.js";
import "@web.awesome.me/webawesome-pro/dist/components/number-input/number-input.js";
import "@web.awesome.me/webawesome-pro/dist/components/slider/slider.js";
import "@web.awesome.me/webawesome-pro/dist/components/color-picker/color-picker.js";
import "@web.awesome.me/webawesome-pro/dist/components/select/select.js";
import "@web.awesome.me/webawesome-pro/dist/components/option/option.js";
import "@web.awesome.me/webawesome-pro/dist/components/switch/switch.js";
// The "Processing" state of a track on the Course maps page.
import "@web.awesome.me/webawesome-pro/dist/components/spinner/spinner.js";
// The messages of the admin, in the corner. wa-toast imports wa-toast-item.
import "@web.awesome.me/webawesome-pro/dist/components/toast/toast.js";
// The ring beside the character count of the Social media page.
import "@web.awesome.me/webawesome-pro/dist/components/progress-ring/progress-ring.js";
// The Social media page.
import "@web.awesome.me/webawesome-pro/dist/components/textarea/textarea.js";
import "@web.awesome.me/webawesome-pro/dist/components/checkbox/checkbox.js";
import "@web.awesome.me/webawesome-pro/dist/components/checkbox-group/checkbox-group.js";
// The Write and Preview tabs of the Social media page. ⚠️ All THREE are necessary: a tab group
// imports neither its tabs nor its panels, and a page with only the group renders the words of
// each panel one after the other, with no tab at all.
import "@web.awesome.me/webawesome-pro/dist/components/tab-group/tab-group.js";
import "@web.awesome.me/webawesome-pro/dist/components/tab/tab.js";
import "@web.awesome.me/webawesome-pro/dist/components/tab-panel/tab-panel.js";
// The schedule fields of the Social media page.
import "@web.awesome.me/webawesome-pro/dist/components/date-input/date-input.js";
import "@web.awesome.me/webawesome-pro/dist/components/time-input/time-input.js";

import DialogController from "./controllers/dialog_controller";
import LocationMapController from "./controllers/location_map_controller";
import MapStatusController from "./controllers/map_status_controller";
import MapPreviewController from "./controllers/map_preview_controller";
import LinkedSidesController from "./controllers/linked_sides_controller";
import RepublishController from "./controllers/republish_controller";
import ToastController from "./controllers/toast_controller";
import SocialController from "./controllers/social_controller";
import SocialPostController from "./controllers/social_post_controller";

// window.Stimulus stays available for a debug session in the console, but the code registers each
// controller through the local variable, because a static analysis cannot see the global.
const application = Application.start();
window.Stimulus = application;
application.register("dialog", DialogController);
application.register("location-map", LocationMapController);
application.register("map-status", MapStatusController);
application.register("map-preview", MapPreviewController);
application.register("linked-sides", LinkedSidesController);
application.register("republish", RepublishController);
application.register("toast", ToastController);
application.register("social", SocialController);
application.register("social-post", SocialPostController);
