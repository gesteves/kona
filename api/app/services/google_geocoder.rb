# Forward-geocodes free text — a street address, a place name — into coordinates, through the same
# Google Geocoding API GoogleMaps reverse-geocodes with. The admin's Location page uses it for the
# address box, where typing a place is the alternative to dropping a pin. Cached in Redis for a day.
class GoogleGeocoder < ApplicationService
  include GoogleApi

  GEOCODE_API_URL = "#{GoogleMaps::GOOGLE_MAPS_API_URL}/geocode/json".freeze

  # @param address [String, nil] Free-text address or place name.
  def initialize(address)
    @address = address.to_s.strip
  end

  # @return [Array(Float, Float), nil] The coordinates, or nil when the address is blank,
  #   resolves to nothing, or the lookup fails.
  def coordinates
    return if @address.blank? || google_api_key.blank?

    # ⚠️ A negative TTL, unlike GoogleMaps' reverse lookups: an address that resolves to nothing is
    # usually a typo, and without one every retype of the same typo re-queries a billed endpoint.
    # Short, because it's a backoff rather than a cache — the address may just have been misspelled.
    point = cached_json(cache_key, expires_in: 1.day, empty_expires_in: 5.minutes) do
      get_json(GEOCODE_API_URL, query: query)&.dig(:results, 0, :geometry, :location)
    end
    return if point.blank?

    # ⚠️ Parsed and range-checked rather than trusted: this pair is stored as the current location,
    # and Location.store validates nothing itself.
    Location.parse(point[:lat], point[:lng])
  end

  private

  # Keyed on a digest, not the address: an address is arbitrary user text, and a raw one would put
  # spaces, colons and newlines into a Redis key. Case-folded so "SFO" and "sfo" share an entry.
  def cache_key
    "google:maps:address:#{cache_version(@address.downcase)}"
  end

  def query
    { address: @address, key: google_api_key, language: "en" }
  end
end
