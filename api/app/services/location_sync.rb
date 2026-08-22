# Sends the current location to Intervals.icu: it updates the profile of the athlete (the city, the
# state, the country, and the timezone) and puts one forecast at the current coordinates in place of
# the weather configuration. It does no write when Intervals.icu already has the same value. Thus
# you can do the full operation more than one time, and a second attempt is safe. This is the same
# as applyLocation of domestique.
class LocationSync
  # This goes at the start of each log line from this service, thus you can find them with grep.
  LOG_PREFIX = "Location sync:".freeze

  # The provider of the one forecast that this code sends. Intervals.icu gives the true forecast id,
  # thus this code sends 0 and never compares that field.
  WEATHER_PROVIDER = "OPEN_WEATHER".freeze

  # The forecast fields that the code compares to decide if the weather configuration needs a write.
  # This is each field but the `id`, which Intervals.icu gives.
  COMPARED_FIELDS = %i[provider location label lat lon enabled].freeze

  def initialize(intervals: Intervals.new)
    @intervals = intervals
  end

  # @param latitude [Float]
  # @param longitude [Float]
  def call(latitude, longitude)
    context = LocationContext.new(latitude, longitude)

    profile_written = sync_athlete_profile(context)
    sync_weather_config(context)

    # Put the value that this code just wrote into the timezone cache, thus athlete_timezone gives
    # it immediately. The Whoop processor and the description generator put each date in a group by
    # that value. Do this only when a profile write contained a timezone. A lookup that fails gives
    # nil, and the code then does not change the cache.
    @intervals.cache_athlete_timezone(context.timezone) if profile_written && context.timezone.present?
  end

  private

  # Updates the profile of the athlete when the city, the state, the country, or the timezone is
  # different from the value in Intervals.icu. It sends only the fields with a value, thus a blank
  # never removes a value that exists. But, as domestique does, a blank field that is different from
  # a stored value still causes the write.
  # @return [Boolean] True if the code did a profile write.
  def sync_athlete_profile(context)
    resolved = {
      city: context.city.presence,
      state: context.state.presence,
      country: context.country.presence,
      timezone: context.timezone.presence
    }
    updates = resolved.compact
    return false if updates.empty?

    current = @intervals.athlete_profile
    return false if resolved.all? { |field, value| value == current[field] }

    @intervals.update_athlete_profile(**updates)
    log_info("updated athlete profile #{updates.inspect}")
    true
  end

  # Puts one forecast at the current location in place of the weather configuration. It does nothing
  # if the current configuration already has the same values. The comparison ignores the id, which
  # Intervals.icu gives.
  def sync_weather_config(context)
    next_forecasts = [ {
      id: 0,
      provider: WEATHER_PROVIDER,
      location: context.location,
      label: context.label,
      lat: context.lat,
      lon: context.lon,
      enabled: true
    } ]
    return if forecasts_equal?(@intervals.weather_config, next_forecasts)

    @intervals.update_weather_config(next_forecasts)
    log_info("updated weather config to #{context.label} (#{context.lat}, #{context.lon})")
  end

  # @return [Boolean] True if the two forecast lists have the same value in each field that the
  #   code compares, and in the same order.
  def forecasts_equal?(existing, next_forecasts)
    return false unless existing.length == next_forecasts.length

    existing.zip(next_forecasts).all? do |current, wanted|
      COMPARED_FIELDS.all? { |field| current[field] == wanted[field] }
    end
  end

  def log_info(message)
    Rails.logger.info("#{LOG_PREFIX} #{message}")
  end
end
