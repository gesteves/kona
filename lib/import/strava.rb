require 'httparty'
require 'active_support/all'

module Import
  module Strava
    STRAVA_API_URL = 'https://www.strava.com/api/v3'

    def self.fetch_totals
      access_token = refresh_access_token
      headers = {
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => "application/json"
      }

      after_time = (Time.now - 1.month).to_i

      response = HTTParty.get("#{STRAVA_API_URL}/athlete/activities", headers: headers, query: { after: after_time, per_page: 200 })

      activities = JSON.parse(response.body)

      totals = {
        swim: { distance: 0.0, activities: 0 },
        bike: { distance: 0.0, activities: 0 },
        run: { distance: 0.0, activities: 0 }
      }

      activities.each do |activity|
        distance_km = activity['distance'] / 1000.0
        type = activity['type']

        case type
        when 'Swim'
          totals[:swim][:distance] += distance_km
          totals[:swim][:activities] += 1
        when 'Ride', 'VirtualRide'
          totals[:bike][:distance] += distance_km
          totals[:bike][:activities] += 1
        when 'Run', 'VirtualRun'
          totals[:run][:distance] += distance_km
          totals[:run][:activities] += 1
        end
      end

      File.open('data/strava.json','w'){ |f| f << totals.to_json }
    end

    def self.refresh_access_token
      client_id = ENV['STRAVA_CLIENT_ID']
      client_secret = ENV['STRAVA_CLIENT_SECRET']
      refresh_token = ENV['STRAVA_REFRESH_TOKEN']

      response = HTTParty.post("#{STRAVA_API_URL}/oauth/token", body: {
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        grant_type: 'refresh_token'
      })

      token_info = JSON.parse(response.body)
      token_info['access_token']
    end
  end
end
