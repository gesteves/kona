# Pushes the current location to Intervals.icu: updates the athlete profile
# (city/state/country/timezone) and replaces the weather config with a single forecast at the
# current coordinates. Each write is skipped when Intervals.icu already matches, so the whole
# operation is idempotent and safe to retry. Faithful port of domestique's applyLocation.
class LocationSync
  # Prefix shared by every log line this service emits, for greppability.
  LOG_PREFIX = "Location sync:".freeze

  # The provider for the single forecast we push. Intervals.icu assigns the real forecast id, so
  # we send 0 and never compare on it.
  WEATHER_PROVIDER = "OPEN_WEATHER".freeze

  # Forecast fields compared when deciding whether the weather config needs a write — everything
  # except the Intervals.icu-assigned `id`.
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

    # Prime the timezone cache with the value we just wrote so athlete_timezone reflects it
    # immediately (the Whoop processor and description generator bucket dates by it). Only when a
    # profile write actually carried a timezone — a failed lookup (nil) leaves the cache alone.
    @intervals.cache_athlete_timezone(context.timezone) if profile_written && context.timezone.present?
  end

  private

  # Updates the athlete profile when any of city/state/country/timezone differs from Intervals.icu.
  # Only the resolved (non-blank) fields are sent, so a blank never clears an existing value — but,
  # matching domestique, a blank field that differs from a stored value still triggers the write.
  # @return [Boolean] whether a profile write actually happened.
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

  # Replaces the weather config with a single forecast at the current location, unless the
  # existing config already matches (ignoring the Intervals.icu-assigned id).
  def sync_weather_config(context)
    next_forecasts = [{
      id: 0,
      provider: WEATHER_PROVIDER,
      location: context.location,
      label: context.label,
      lat: context.lat,
      lon: context.lon,
      enabled: true
    }]
    return if forecasts_equal?(@intervals.weather_config, next_forecasts)

    @intervals.update_weather_config(next_forecasts)
    log_info("updated weather config to #{context.label} (#{context.lat}, #{context.lon})")
  end

  # @return [Boolean] whether the two forecast lists match on every compared field, in order.
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
