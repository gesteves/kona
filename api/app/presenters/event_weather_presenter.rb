# Holds the data decisions of the race-day weather fragment of each event, thus the template does
# not make them. It uses the helper code for the event forecast, the SF Bay conditions, and the SF
# locality check, and it does not copy that code.
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

  # @return [OpenStruct, nil] The forecast day for the date of the event. It has the sunrise and
  #   the sunset.
  def forecast_day
    return @forecast_day if defined?(@forecast_day)
    @forecast_day = event_forecast_day(event)
  end

  # @return [OpenStruct, nil] The daytime forecast for the date of the event.
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

  # ⚠️ The bay checks test each field, and not `bay` alone. Goodspeed omits some readings, and one
  # field that is absent must remove its own line and not give the full widget a 500.
  # @return [Boolean] True when the bay entry has a water temperature.
  def water_temperature?
    bay.present? && bay.water_temp_c.present?
  end

  # @return [Boolean] True when the bay entry has the speed and the bearing of the current.
  def bay_current?
    bay.present? && bay.current_speed_ms.present? && bay.current_bearing_deg.present?
  end

  # The direction that the current comes from, in degrees. The bearing of Goodspeed is the
  # direction that the current goes to, and the arrow of the widget turns as a wind arrow does.
  # @return [Numeric]
  def bay_current_from
    (bay.current_bearing_deg + 180) % 360
  end

  # @return [Numeric] The humidity of the forecast, in percent. Call it only with a humidity.
  def humidity_percent
    forecast.humidity * 100
  end

  # @return [Numeric] The chance of precipitation, in percent. Call it only with a chance.
  def precipitation_percent
    forecast.precipitation_chance * 100
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
