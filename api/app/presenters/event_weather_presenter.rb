# Holds the data decisions of the race-day weather fragment of each event, thus the template does
# not make them. It uses the helper code that exists — the event forecast lookup, the SF Bay current
# lookup, and the SF locality check — and it does not copy that code.
class EventWeatherPresenter
  include EventsHelper
  include BayHelper
  include LocationHelper

  attr_reader :event

  # @param event [OpenStruct] The event object, with sys, date, location, aqi, and weather.
  # @param goodspeed [OpenStruct, nil] The bay-conditions data. {bay} uses it.
  def initialize(event, goodspeed: nil)
    @event = event
    @goodspeed = goodspeed
  end

  # The forecast day for the date of the event. It has the sunrise and the sunset.
  # @return [OpenStruct, nil]
  def forecast_day
    return @forecast_day if defined?(@forecast_day)
    @forecast_day = event_forecast_day(event)
  end

  # The daytime forecast for the date of the event.
  # @return [OpenStruct, nil]
  def forecast
    forecast_day&.daytime_forecast
  end

  # The SF Bay conditions entry that is nearest to the event, or nil if the event is not in SF.
  # @return [OpenStruct, nil]
  def bay
    return @bay if defined?(@bay)
    return @bay = nil unless in_san_francisco?(event.location)

    at = begin
      Time.parse(event.date.to_s)
    rescue ArgumentError, TypeError
      nil
    end
    @bay = at && bay_conditions_at(@goodspeed, at)
  end

  # @return [OpenStruct, nil] The air-quality reading of the event.
  def aqi
    event.aqi
  end

  # @return [String, nil] The raw sunrise timestamp, from the forecast day.
  def sunrise
    forecast_day&.sunrise
  end

  # @return [String, nil] The raw sunset timestamp, from the forecast day.
  def sunset
    forecast_day&.sunset
  end

  # @return [String, nil] The IANA timezone id of the location of the event.
  def time_zone_id
    event.location&.time_zone&.time_zone_id
  end

  # The name of the precipitation for the forecast. A "clear" precipitation type counts as rain.
  # @return [String, nil]
  def precipitation_label
    type = forecast&.precipitation_type
    return if type.blank?

    type.downcase == "clear" ? "rain" : type.downcase
  end
end
