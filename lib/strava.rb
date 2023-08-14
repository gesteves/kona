require 'httparty'

module Strava
  STRAVA_API_URL = 'https://www.strava.com/api/v3'

  def self.stats
    access_token = refresh_access_token
    headers = {
      "Authorization" => "Bearer #{access_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.get("#{STRAVA_API_URL}/athletes/#{ENV['STRAVA_ATHLETE_ID']}/stats", headers: headers)
    stats = JSON.parse(response.body)

    # Rename key to avoid warning about conflict with a built-in Ruby method
    stats.each_key do |k|
      stats[k]['activities'] = stats[k].delete('count') if stats[k].is_a?(Hash) && stats[k]['count'].present?
    end

    File.open('data/strava.json','w'){ |f| f << stats.to_json }
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
