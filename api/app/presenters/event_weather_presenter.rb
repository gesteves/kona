# Encapsulates the data decisions behind the per-event race-day weather fragment, keeping
# them out of the template. Reuses the existing helper logic (event forecast lookup, the
# SF-Bay current lookup, the SF locality check) rather than duplicating it.
class EventWeatherPresenter
  include EventsHelper
  include BayHelper
  include LocationHelper

  attr_reader :event

  # @param event [OpenStruct] The wrapped event (sys/date/location/aqi/weather).
  # @param goodspeed [OpenStruct, nil] The bay-conditions data (used by {bay}).
  def initialize(event, goodspeed: nil)
    @event = event
    @goodspeed = goodspeed
  end

  # The forecast day covering the event's date (carries sunrise/sunset).
  # @return [OpenStruct, nil]
  def forecast_day
    return @forecast_day if defined?(@forecast_day)
    @forecast_day = event_forecast_day(event)
  end

  # The daytime forecast for the event's date.
  # @return [OpenStruct, nil]
  def forecast
    forecast_day&.daytime_forecast
  end

  # The nearest SF Bay conditions entry to the event, or nil when the event isn't in SF.
  # @return [OpenStruct, nil]
  def bay
    return @bay if defined?(@bay)
    @bay = in_san_francisco?(event.location) ? bay_conditions_at(Time.parse(event.date)) : nil
  end

  # @return [OpenStruct, nil] The event's air-quality reading.
  def aqi
    event.aqi
  end

  # @return [String, nil] The sunrise timestamp (raw, from the forecast day).
  def sunrise
    forecast_day&.sunrise
  end

  # @return [String, nil] The sunset timestamp (raw, from the forecast day).
  def sunset
    forecast_day&.sunset
  end

  # @return [String, nil] The IANA timezone id for the event's location.
  def time_zone_id
    event.location&.time_zone&.time_zone_id
  end

  # The precipitation noun for the forecast, treating a "clear" precipitation type as rain.
  # @return [String, nil]
  def precipitation_label
    type = forecast&.precipitation_type
    return if type.blank?

    type.downcase == "clear" ? "rain" : type.downcase
  end
end
