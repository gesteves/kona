import * as Turbo from '@hotwired/turbo';
import { Application } from '@hotwired/stimulus';
import Handlebars from 'handlebars';

import BackToTopController from './controllers/back_to_top_controller';
import ClipboardController from './controllers/clipboard_controller';
import ImagePlaceholderController from './controllers/image_placeholder_controller';
import LiveUpdateController from './controllers/live_update_controller';
import NavController from './controllers/nav_controller';
import NotificationsController from './controllers/notifications_controller';
import OauthCallbackController from './controllers/oauth_callback_controller';
import PageController from './controllers/page_controller';
import RelativeDateController from './controllers/relative_date_controller';
import ShareController from './controllers/share_controller';
import UnitsController from './controllers/units_controller';

window.Stimulus = Application.start();
Stimulus.register('back-to-top', BackToTopController);
Stimulus.register('clipboard', ClipboardController);
Stimulus.register('image-placeholder', ImagePlaceholderController);
Stimulus.register('live-update', LiveUpdateController);
Stimulus.register('nav', NavController);
Stimulus.register('notifications', NotificationsController);
Stimulus.register('oauth-callback', OauthCallbackController);
Stimulus.register('page', PageController);
Stimulus.register('relative-date', RelativeDateController);
Stimulus.register('share', ShareController);
Stimulus.register('units', UnitsController);

Handlebars.registerHelper('pluralize', function (count, singular, plural) {
  return count === 1 ? singular : plural;
});
Handlebars.registerHelper('formatNumber', function (number) {
  if (number == null) return 0; // Default to 0 if number is null or undefined
  return new Intl.NumberFormat('en-US').format(number);
});
