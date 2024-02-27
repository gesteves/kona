# Kona

This is a very fast and streamlined blogging system written in [Middleman](https://middlemanapp.com/), powered by [Contentful](https://www.contentful.com/), and hosted on [Netlify](https://www.netlify.com/). Check it out at *[Given to Tri](https://www.giventotri.com/)*.

[![Netlify Status](https://api.netlify.com/api/v1/badges/f87f4e00-a5a5-436d-b6df-a3628c3fb919/deploy-status)](https://app.netlify.com/sites/giventotri/deploys)

## Setup

Kona leverages Middleman's [data files](https://middlemanapp.com/advanced/data-files/) by making API calls to various services, manipulating the responses as needed, and dropping the data in the `data/` folder as JSON files, which makes them available as data in the app's templates and helper methods. To do this, you'll need to set up these services and add the necessary credentials as environment variables. Check out the `.env.example` file in the repo to see the credentials you'll need. You'll want to add them to an `.env` file and to the site's environment variables in Netlify.

### Required services

#### Netlify

Kona can technically be hosted basically anywhere because it's just a static site generator, but it works much better on Netlify since it's set up to use Netlify features such as [build hooks](https://docs.netlify.com/configure-builds/build-hooks/), [functions](https://docs.netlify.com/functions/overview/) and [Image CDN](https://docs.netlify.com/image-cdn/overview/).

#### Contentful

[Contentful](https://www.contentful.com/) is the CMS used to author most of the site's content, including the blog articles. Unfortunately, there's no quick way to set this up, but you'll want a content model like this:

![cf-Given to Tri-master-2024-02-26_14-27-43](https://github.com/gesteves/kona/assets/6379/02191523-7786-4b36-860e-a00671938e1e)

Then head over to Settings > API Keys in Contentful, create a new API key, copy the Space ID and Content Preview API access token, and add them to the `CONTENTFUL_SPACE` and `CONTENTFUL_TOKEN` environment variables. You'll also probably want to install the Netlify app within Contentful, which will rebuild the site whenever new content is published or updated in Contentful.

#### Font Awesome

Kona uses Font Awesome for the various icons on the site. Rather than store the SVGs themselves in the repo, it pulls them from the API at build time. You'll need a Font Awesome Pro account, and an API token with a "Pro icons and metadata" read scope, which you can set up at https://fontawesome.com/account/general. Add it to the `FONT_AWESOME_API_TOKEN` environment variable.

#### Redis

Kona uses redis to cache some of the API responses from various services, which makes deploys a little speedier. You can set up a free instance at https://redis.com and add the credentials to the appropriate environment variables.

### Optional services

The services below aren't required to run Kona, but they provide additional data, mainly the various stats on the home page.

#### Strava

Kona uses Strava to show the activity stats on the home page. You'll need to set up a new application at https://www.strava.com/settings/api and add the Client ID, Client Secret and Refresh Token from that page to the corresponding environment variables. You'll also need your Athlete ID, which is in the URL of your Strava profile page.

#### Google Maps

Kona uses Google Maps to geocode the location shown on the home page, and fetch pollen and air quality data. You'll need to set up a project and an API key at https://console.cloud.google.com and make sure the API key has access to the following APIs: 

* Geocoding API
* Time Zone API
* Maps Elevation API
* Air Quality API
* Pollen API

Then, add the API key to the `GOOGLE_API_KEY` environment variable.

#### WeatherKit

Kona uses [WeatherKit](https://developer.apple.com/weatherkit/) to show the weather conditions and forecast on the home page. This is a chore to set up, but follow [these instructions](https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api) and add the credentials to the environment variables.

This requires Google Maps to be set up to work.

#### Purple Air

Kona uses [Purple Air](https://www2.purpleair.com/) to show hyperlocal air quality data on the weather section on the home page. You can get an API key at https://develop.purpleair.com and add it to the `PURPLEAIR_API_KEY` environment variable.

This requires Google Maps and WeatherKit to be set up to work.

#### Location

To set the location used for the weather conditions and forecast on the home page, add it as a comma-separated pair of latitude/longitude coordinates to the `LOCATION` environment variable, like `"19.639133263373843, -155.9967081931534"`. You can also pass them as JSON in the body of a [Netlify build hook](https://docs.netlify.com/configure-builds/build-hooks/) to update them (and the website) automatically.

For example, making the following request...

```
curl -X POST <NETLIFY_BUILD_HOOK_URL> -H "Content-Type: application/json" -d '{ "latitude": 19.639133263373843, "longitude": -155.9967081931534 }'
```

...will rebuild the site to show the conditions in Kailua-Kona on the home page. This requires Google Maps and WeatherKit to be set up to work.

#### TrainerRoad

This doesn't do much, it's simply used to check if a workout is scheduled for today and adjust some messaging on the home page accordingly. You can grab the calendar URL from https://www.trainerroad.com/app/profile/calendar-sync and add it to the environment variable.

#### Netlify build hook

To keep the information on the home page current, you can use a [Netlify build hook](https://docs.netlify.com/configure-builds/build-hooks/) to rebuild the site hourly. To set this up, create a build hook in the site's build configuration and add it to the `BUILD_HOOK_URL` environment variable.

### Running the site locally

Requirements:

* Ruby
* Node
* [Netlify CLI](https://docs.netlify.com/cli/get-started/)

Steps:

1. Set up the services above and add the environment variables to either the site's configuration in Netlify or to the `.env` file
2. Install dependencies with `bundle install` and `npm install`
4. Build the site with `netlify build`, which will run the data import tasks
5. Run the local server with `netlify dev`
6. Optionally, if you're going to make changes to the JS files, run `npm run watch` in another terminal tab
7. If you want to reload the data without rebuilding the site, run `bundle exec rake import`
