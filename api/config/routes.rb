Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Widget fragments embedded into the static site, under the /api namespace.
  get "/api/activity-stats" => "api/activity_stats#show"

  # Current weather widget markup.
  get "/api/weather/current" => "api/weather#current"

  # Per-event race-day weather, keyed by Contentful event ID.
  get "/api/weather/event/:id" => "api/weather#event"

  # Current location, geocoded — the source of truth the static-site build fetches.
  get "/api/location" => "api/location#show"

  # All-time Plausible pageview count for an article, keyed by Contentful ID.
  get "/api/plausible/pageviews/:id" => "api/plausible#pageviews"

  # Returns the Whoop stats markup.
  get "/api/whoop" => "api/whoop#show"

  # Whoop OAuth flow (owner-only authorize, public callback validated by state).
  get "/whoop/auth" => "whoop_oauth#authorize"
  get "/whoop/callback" => "whoop_oauth#callback"

  # Sets the current location (bearer-token-secured), replacing the old Netlify build hook.
  post "/location" => "api/location#create"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
