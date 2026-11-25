# The WeatherKit payload of one location, with its timezone: the weather now, the forecast of today
# and of tomorrow, the sun times, the time of day, and the alerts. Make one for each request.
class Forecast
  include TimeHelper # parse_time

  # @param weather [OpenStruct, nil] The payload of WeatherKit#data. With nil, the time of day
  #   comes from the clock.
  # @param time_zone [String] An IANA timezone id.
  def initialize(weather, time_zone)
    @weather = weather
    @time_zone = time_zone
  end

  # Checks the exact parts of the data that the weather summary uses. A check of #today alone is
  # not sufficient: #rest_of_day changes to the overnight forecast in the evening. Thus a payload
  # with no overnight data would pass this check and then stop the evening summary.
  # @return [Boolean]
  def current?
    current.present? && today.present? && rest_of_day.present?
  end

  # @return [OpenStruct, nil] The weather now.
  def current
    @weather&.current_weather
  end

  # ⚠️ The forecast times go through parse_time, which gives nil for a value that is absent or
  # broken. `Time.parse` raises on those, and the widget then gives a 500 in place of an empty
  # body: the controller calls #current? before its `safely` blocks.
  # @return [OpenStruct, nil] The forecast day that holds this moment.
  def today
    return @today if defined?(@today)

    now = Time.now
    @today = @weather&.forecast_daily&.days&.find do |d|
      start_at = parse_time(d.forecast_start)
      end_at = parse_time(d.forecast_end)
      d.rest_of_day_forecast.present? && start_at && end_at && start_at <= now && end_at >= now
    end
  end

  # @return [OpenStruct, nil] The forecast for the rest of today, or the overnight forecast in the
  #   evening.
  def rest_of_day
    evening? ? today&.overnight_forecast : today&.rest_of_day_forecast
  end

  # @return [OpenStruct, nil] The first forecast day that starts after this moment.
  def tomorrow
    now = Time.now
    @weather&.forecast_daily&.days&.find do |d|
      start_at = parse_time(d.forecast_start)
      start_at && start_at > now
    end
  end

  # @return [ActiveSupport::TimeWithZone, nil]
  def sunrise
    parse_time(today&.sunrise)&.in_time_zone(@time_zone)
  end

  # @return [ActiveSupport::TimeWithZone, nil]
  def sunset
    parse_time(today&.sunset)&.in_time_zone(@time_zone)
  end

  # @return [ActiveSupport::TimeWithZone, nil]
  def tomorrows_sunrise
    parse_time(tomorrow&.sunrise)&.in_time_zone(@time_zone)
  end

  # Tells if it is daytime: between the sunrise and the sunset of today, when the payload has those
  # two times. In all other conditions, it tests the clock against 6am and 6pm.
  def daytime?
    now = Time.current.in_time_zone(@time_zone)
    if @weather.present?
      sunrise_time = sunrise
      sunset_time = sunset
      return now.hour >= 6 && now.hour < 18 unless sunrise_time && sunset_time
      # The exact times. An hour that starts before the sunset is not the evening.
      now >= sunrise_time && now < sunset_time
    else
      now.hour >= 6 && now.hour < 18
    end
  end

  # Tells if it is evening: after the sunset of today, when the payload has that time. In all other
  # conditions, it tests the clock against 6pm.
  def evening?
    now = Time.current.in_time_zone(@time_zone)
    if @weather.present?
      sunset_time = sunset
      return now.hour >= 18 unless sunset_time
      now >= sunset_time
    else
      now.hour >= 18
    end
  end

  # @return [String] "Tonight" in the evening, and "Today" at each other time.
  def today_or_tonight
    evening? ? "Tonight" : "Today"
  end

  # @return [Array<OpenStruct>] The weather alerts that apply now, the most important first. Each
  #   alert token is there one time.
  def alerts
    return [] if @weather&.weather_alerts&.alerts.blank?

    @weather.weather_alerts.alerts.group_by(&:token)
            .map { |_token, same| same.min_by(&:precedence) }
            .sort_by(&:precedence)
  end
end
