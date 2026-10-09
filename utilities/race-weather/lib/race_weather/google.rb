require 'httparty'

module RaceWeather
  # Finds the coordinates and the IANA time zone of a place with Google Maps.
  module Google
    extend self

    GOOGLE_MAPS_API_URL = 'https://maps.googleapis.com/maps/api'.freeze
    HTTP_TIMEOUT = 15

    # @param address [String] For example "Great Falls, Montana".
    # @return [Hash, nil] `{ name:, lat:, lng: }`, with the coordinates to 4 places, or nil when
    #   Google finds nothing.
    def geocode(address)
      body = get('geocode/json', address: address, language: 'en')
      result = body&.dig('results', 0)
      return unless result

      location = result.dig('geometry', 'location')
      { name: result['formatted_address'], lat: location['lat'].round(4), lng: location['lng'].round(4) }
    end

    # @param lat [Float]
    # @param lng [Float]
    # @return [String, nil] An IANA time zone id, for example "America/Denver".
    def time_zone(lat, lng)
      get('timezone/json', location: "#{lat},#{lng}", timestamp: Time.now.to_i)&.dig('timeZoneId')
    end

    private

    # @return [Hash, nil] The body, when its status is OK.
    def get(path, query)
      response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/#{path}",
                              query: query.merge(key: ENV.fetch('GOOGLE_API_KEY', nil)),
                              timeout: HTTP_TIMEOUT)
      body = response.parsed_response
      body if response.success? && body.is_a?(Hash) && body['status'] == 'OK'
    end
  end
end
