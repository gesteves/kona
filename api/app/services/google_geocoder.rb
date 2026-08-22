# Changes free text — a street address or a place name — into coordinates. It uses the same Google
# Geocoding API that GoogleMaps uses in the other direction. The Location page of the admin uses it
# for the address box, where a person types a place in place of a pin on the map. Redis caches each
# result for a day.
class GoogleGeocoder < ApplicationService
  include GoogleApi

  GEOCODE_API_URL = "#{GoogleMaps::GOOGLE_MAPS_API_URL}/geocode/json".freeze

  # @param address [String, nil] An address or a place name, as free text.
  def initialize(address)
    @address = address.to_s.strip
  end

  # @return [Array(Float, Float), nil] The coordinates, or nil when the address is blank, when the
  #   geocoder finds nothing, and when the lookup fails.
  def coordinates
    return if @address.blank? || google_api_key.blank?

    # ⚠️ There is a TTL for an empty result here, and the reverse lookups of GoogleMaps have none. An
    # address that gives nothing is usually a typing error, and without this TTL each new attempt
    # with the same error calls an endpoint that costs money. The time is short, because it is a
    # delay and not a cache: the person can correct the address.
    point = cached_json(cache_key, expires_in: 1.day, empty_expires_in: 5.minutes) do
      get_json(GEOCODE_API_URL, query: query)&.dig(:results, 0, :geometry, :location)
    end
    return if point.blank?

    # ⚠️ The code parses this pair and checks its range. It does not accept it as it is: the app
    # stores this pair as the current location, and Location.store checks nothing.
    Location.parse(point[:lat], point[:lng])
  end

  private

  # The key is a digest, and not the address. An address is text that a user types, and the raw text
  # would put a space, a colon, and a newline into a Redis key. The code makes the text lowercase,
  # thus "SFO" and "sfo" share one entry.
  def cache_key
    "google:maps:address:#{cache_version(@address.downcase)}"
  end

  def query
    { address: @address, key: google_api_key, language: "en" }
  end
end
