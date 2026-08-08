// Side-effect import: Turbo self-installs on load and nothing here references its exports.
import '@hotwired/turbo';
import { Application } from '@hotwired/stimulus';
import '@web.awesome.me/webawesome-pro/dist/styles/themes/default.css';
import '@web.awesome.me/webawesome-pro/dist/components/skeleton/skeleton.js';
import '@web.awesome.me/webawesome-pro/dist/components/relative-time/relative-time.js';
import '@web.awesome.me/webawesome-pro/dist/components/toast/toast.js';
import '@web.awesome.me/webawesome-pro/dist/components/input/input.js';
import '@web.awesome.me/webawesome-pro/dist/components/textarea/textarea.js';
import '@web.awesome.me/webawesome-pro/dist/components/button/button.js';
import '@web.awesome.me/webawesome-pro/dist/components/scroller/scroller.js';
import './lib/patch_scroller_aria';

import BackToTopController from './controllers/back_to_top_controller';
import ClipboardController from './controllers/clipboard_controller';
import ContactController from './controllers/contact_controller';
import CurrentYearController from './controllers/current_year_controller';
import ImagePlaceholderController from './controllers/image_placeholder_controller';
import LiveUpdateController from './controllers/live_update_controller';
import NavController from './controllers/nav_controller';
import PageController from './controllers/page_controller';
import PublishDateController from './controllers/publish_date_controller';
import SearchController from './controllers/search_controller';
import ShareController from './controllers/share_controller';
import UnitsController from './controllers/units_controller';

// window.Stimulus stays exposed for console debugging, but registration goes through the
// local binding — the bare global was invisible to static analysis.
const application = Application.start();
window.Stimulus = application;
application.register('back-to-top', BackToTopController);
application.register('clipboard', ClipboardController);
application.register('contact', ContactController);
application.register('current-year', CurrentYearController);
application.register('image-placeholder', ImagePlaceholderController);
application.register('live-update', LiveUpdateController);
application.register('nav', NavController);
application.register('page', PageController);
application.register('publish-date', PublishDateController);
application.register('search', SearchController);
application.register('share', ShareController);
application.register('units', UnitsController);
