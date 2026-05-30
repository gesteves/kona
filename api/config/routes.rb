Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Returns the activity-stats markup embedded into the static site.
  get "/activity-stats" => "activity_stats#show"

  # Returns the weather widget markup embedded into the static site.
  get "/weather" => "weather#show"

  # Per-event race-day weather, keyed by Contentful event ID.
  get "/api/weather/event/:id" => "api/weather#event"

  # Returns the Whoop stats markup embedded into the static site.
  get "/whoop" => "whoop#show"

  # Whoop OAuth flow (owner-only authorize, public callback validated by state).
  get "/whoop/auth" => "whoop_oauth#authorize"
  get "/whoop/callback" => "whoop_oauth#callback"

  # Sets the current location (bearer-token-secured), replacing the old Netlify build hook.
  post "/location" => "location#create"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
