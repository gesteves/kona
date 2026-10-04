namespace :strava do
  desc "Makes the Strava webhook subscription, or finds the one that exists, and stores its id. " \
       "The callback is https://<API_HOST>/webhooks/strava; CALLBACK_URL=<url> replaces it. " \
       "⚠️ The app must already serve that URL with STRAVA_WEBHOOK_VERIFY_TOKEN."
  task subscribe: :environment do
    callback_url = ENV["CALLBACK_URL"].presence
    callback_url ||= "https://#{ENV['API_HOST']}/webhooks/strava" if ENV["API_HOST"].present?
    abort("Set API_HOST, or give CALLBACK_URL.") if callback_url.nil?

    strava = Strava.new
    abort("Set STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET.") unless strava.valid_credentials?

    puts "Strava subscription #{strava.subscribe!(callback_url)} → #{callback_url}"
  end
end
