require 'httparty'
require 'json'
require_relative 'format'
# ⚠️ This is the one copy of the EPA math in utilities/, and CI checks it. Do not copy it here.
require_relative '../../../aqi-map/lib/epa_aqi'

module RaceWeather
  # Gives the 24-hour AQI of a past day from the PurpleAir sensor history. The sensor query follows
  # `sensors_in_bounds` in aqi-map/app.rb.
  module PurpleAir
    extend self

    PURPLE_AIR_API_URL = 'https://api.purpleair.com/v1'.freeze
    # The half width of the search box.
    SEARCH_KM = 15
    # The same limit as the api and aqi-map. The history has no confidence, thus this is the value
    # of today.
    MIN_CONFIDENCE = 50
    # The most sensors to try for one day, nearest first.
    MAX_TRIES = 3
    # A sensor with fewer hourly rows does not cover the day.
    MIN_HOURS = 18
    # The history endpoint permits one request each second for each key.
    RATE_LIMIT_SLEEP = 1.1
    HTTP_TIMEOUT = 30

    # @return [Boolean] True when the PurpleAir key has a value.
    def configured?
      !ENV['PURPLEAIR_API_KEY'].to_s.empty?
    end

    # The outdoor sensors near a location, with their distance in km, nearest first.
    # ⚠️ `max_age: 0` is necessary. The default of 7 days removes each sensor that went offline
    # after the day, and gives no message.
    # @param lat [Float]
    # @param lng [Float]
    # @return [Array<Hash>]
    # @see https://api.purpleair.com/#api-sensors-get-sensors-data
    def sensors(lat, lng)
      body = get('/sensors', bounding_box(lat, lng).merge(
        fields: 'name,latitude,longitude,confidence,date_created,last_seen',
        location_type: 0,
        max_age: 0
      ))
      fields = body['fields']
      Array(body['data']).filter_map do |values|
        sensor = fields.zip(values).to_h
        next if sensor['latitude'].nil? || sensor['longitude'].nil?
        next if sensor['confidence'].to_i < MIN_CONFIDENCE

        sensor.merge('km' => distance_km(lat, lng, sensor['latitude'], sensor['longitude']))
      end.sort_by { |sensor| sensor['km'] }
    end

    # The 24-hour AQI from the nearest sensor that covers the day. The EPA correction applies to
    # each hour, and the AQI comes from the mean of the corrected values. An hour whose correction
    # is below zero is ignored, as in the api.
    # @param sensors [Array<Hash>] From #sensors.
    # @param from [Time] The start of the day.
    # @param to [Time] The end of the day.
    # @return [Hash, nil] `{ aqi:, category:, sensor:, km: }`, or nil when no sensor covers the day.
    def daily_aqi(sensors, from:, to:)
      candidates = sensors.select do |sensor|
        sensor['date_created'].to_i < from.to_i && sensor['last_seen'].to_i > to.to_i
      end

      candidates.first(MAX_TRIES).each do |sensor|
        values = hourly_pm25(sensor['sensor_index'], from, to)
        next if values.size < MIN_HOURS

        aqi = EpaAqi.format_aqi(values.sum / values.size)
        return { aqi: aqi, category: Format.aqi_category(aqi), sensor: sensor['name'], km: sensor['km'].round(1) }
      end
      nil
    end

    private

    # @return [Array<Float>] The corrected PM2.5 of each hour.
    # @see https://api.purpleair.com/#api-sensors-get-sensor-history
    def hourly_pm25(sensor_index, from, to)
      body = get("/sensors/#{sensor_index}/history", {
        fields: 'pm2.5_atm,humidity',
        average: 60,
        start_timestamp: from.to_i,
        end_timestamp: to.to_i
      })
      sleep RATE_LIMIT_SLEEP

      column = Array(body['fields']).each_with_index.to_h
      Array(body['data']).filter_map do |values|
        corrected = EpaAqi.apply_epa_correction(values[column['pm2.5_atm']], values[column['humidity']])
        corrected if corrected && !corrected.negative?
      end
    end

    # ⚠️ A 200 does not show a success: DataInitializingError answers with 200, and an incomplete
    # response has a top-level `error`. Thus this checks the body too.
    def get(path, query)
      response = HTTParty.get("#{PURPLE_AIR_API_URL}#{path}",
                              query: query,
                              headers: { 'X-API-Key' => ENV.fetch('PURPLEAIR_API_KEY', nil) },
                              timeout: HTTP_TIMEOUT)
      body = JSON.parse(response.body.to_s)
      raise "PurpleAir #{body['error']}: #{body['description']}" if body.is_a?(Hash) && body['error']
      raise "PurpleAir returned status #{response.code}" unless response.success? && body.is_a?(Hash)

      body
    rescue JSON::ParserError
      raise "PurpleAir returned a body that is not JSON (status #{response&.code})"
    end

    def bounding_box(lat, lng)
      lat_delta = SEARCH_KM / 111.0
      lng_delta = SEARCH_KM / (111.0 * Math.cos(lat * Math::PI / 180))
      { nwlat: (lat + lat_delta).clamp(-90, 90), selat: (lat - lat_delta).clamp(-90, 90),
        nwlng: lng - lng_delta, selng: lng + lng_delta }
    end

    def distance_km(lat1, lng1, lat2, lng2)
      radians = ->(degrees) { degrees * Math::PI / 180 }
      a = Math.sin(radians.(lat2 - lat1) / 2)**2 +
          Math.cos(radians.(lat1)) * Math.cos(radians.(lat2)) * Math.sin(radians.(lng2 - lng1) / 2)**2
      6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
  end
end
