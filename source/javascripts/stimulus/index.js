import * as Turbo from '@hotwired/turbo';
import { Application } from '@hotwired/stimulus';
import { definitionsFromContext } from '@hotwired/stimulus-webpack-helpers';
import Handlebars from 'handlebars';

window.Stimulus = Application.start();
const context = require.context('./controllers', true, /\.js$/);
Stimulus.load(definitionsFromContext(context));
Handlebars.registerHelper('pluralize', function (count, singular, plural) {
  return count === 1 ? singular : plural;
});
Handlebars.registerHelper('formatNumber', function (number) {
  if (number == null) return 0; // Default to 0 if number is null or undefined
  return new Intl.NumberFormat('en-US').format(number);
});
