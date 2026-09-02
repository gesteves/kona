# Makes the text summary of the current-weather widget. It holds the rules (is the weather good or
# bad, and is it the indoor season) and the methods that make each sentence. Those stay out of the
# helper layer, which keeps the small format and selection methods (WeatherHelper).
# This is a plain object: it holds the weather data of the request as its own state, and it gives
# that data to each helper function that it calls.
class WeatherSummaryPresenter
  include WeatherHelper   # forecast selection + condition/temperature/wind formatting
  include MarkupHelper    # units_tag
  include UnitsHelper     # unit conversions + ActiveSupport::NumberHelper
  include TimeHelper      # meridiem_abbr (via format_time)
  include TextHelper      # comma_join_with_and / with_indefinite_article / remove_widows
  include MarkdownHelper  # markdown_to_html for the composed summary
  include WorkoutsHelper  # workout_scheduled?
  include EventsHelper    # todays_race / race_day?
  include LocationHelper  # format_location / format_elevation / in_jackson_hole?
  include BayHelper       # bay_water_temperature_sentence

  # For the content_tag with no block that the format helpers make: units_tag and
  # beaufort_description.
  include ActionView::Helpers::TagHelper

  def initialize(weather: nil, location: nil, air_quality: nil, pollen: nil, events: nil, goodspeed: nil, workouts: nil, time_zone: nil)
    @weather = weather
    @location = location
    @air_quality = air_quality
    @pollen = pollen
    @events = events
    @goodspeed = goodspeed
    @workouts = workouts
    @time_zone = time_zone.presence || TimeZoneResolver.default
  end

  # Each of the two forecast selections reads the daily forecast from the start and parses two
  # timestamps for each day, and more than one sentence needs them. This class keeps the values,
  # because the state of the request is already here. WeatherHelper does not keep them, because it
  # is a set of functions that use only their arguments, on purpose.
  #
  # ⚠️ The value goes on `todays_forecast` itself, and not on another method, because sunrise and
  # sunset, and through them daytime?, evening?, and rest_of_day_forecast, each call it. One summary
  # calls it approximately ten times. A new selection method here makes all of those fast. Another
  # method around it would cover only the direct callers. Each other weather object goes to the
  # original method.
  def todays_forecast(weather = @weather)
    return super unless weather.equal?(@weather)
    return @todays_forecast if defined?(@todays_forecast)

    @todays_forecast = super
  end
  alias today todays_forecast

  def rest_of_day
    return @rest_of_day if defined?(@rest_of_day)
    @rest_of_day = rest_of_day_forecast(@weather, @time_zone)
  end

  # The same shape for the events: race_day? calls todays_race, and the summary calls it five
  # times.
  def todays_race(events = @events, time_zone = @time_zone)
    return super unless events.equal?(@events) && time_zone == @time_zone
    return @todays_race if defined?(@todays_race)

    @todays_race = super
  end

  # The full summary as HTML. Each sentence is in a span.
  def weather_summary
    summary = []
    summary << race_day
    summary << smooth
    summary << current_location
    summary << elevation
    summary << currently
    summary << bay_water_temperature_sentence(@goodspeed, @location)
    summary << current_aqi
    summary << format_pollen_level
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{t}</span>" }.join(" "))
  end

  # The icon id for the current conditions, for the header of the widget. It knows the day and the
  # night.
  def icon
    weather_icon(current_weather(@weather)&.condition_code, :auto, weather: @weather, time_zone: @time_zone)
  end

  # The weather alerts that apply now. The code removes the copies and puts them in order for the
  # screen.
  def alerts
    weather_alerts(@weather)
  end

  def race_day
    "**It's race day!**" if race_day?(@events, @time_zone) && !evening?(@weather, @time_zone)
  end

  def current_location
    location = "I'm currently in **#{location_name}**"
    race = todays_race(@events, @time_zone)
    the = race&.title&.downcase&.start_with?("ironman") ? "" : "the"
    location << ", racing #{the} **#{race.title}**" if race_day?(@events, @time_zone) && !evening?(@weather, @time_zone)
    location
  end

  def elevation
    formatted = format_elevation(@location&.elevation)
    return if formatted.blank?
    "The elevation is #{formatted}"
  end

  def smooth
    "Man, it's a hot one!" if !race_day?(@events, @time_zone) && hot? && daytime?(@weather, @time_zone)
  end

  def currently
    current = current_weather(@weather)
    # The temperature is the content of the sentence. Without it there is nothing to say, thus the
    # code removes the full sentence and does not write "with a temperature of".
    temperature = format_temperature(current&.temperature)
    return if temperature.blank?

    apparent = format_temperature(current.temperature_apparent)
    text = []
    text << "#{format_current_condition(current.condition_code).capitalize}, with a temperature of #{temperature}"
    text << "which feels like #{apparent}" unless hide_apparent_temperature? || apparent.blank?
    text << "#{number_to_percentage(current.humidity * 100, precision: 0)} humidity" unless current.humidity.blank? || current.humidity.zero?
    text << wind
    comma_join_with_and(text.compact)
  end

  def wind
    current = current_weather(@weather)
    direction = wind_direction(current&.wind_direction)
    # ⚠️ Do the check before the format, and not after. WeatherKit omits some fields, and the
    # `.round` in format_wind_speed makes a windSpeed that is absent into a NoMethodError. The
    # widget then gives a 500 and does not go away. A nil speed becomes 0 knots, which is
    # Beaufort 0, thus this method returns here.
    wind_speed_knots = kph_to_knots(current&.wind_speed.to_f)
    return if direction.blank? || beaufort_number(wind_speed_knots).zero?

    formatted_wind_speed = format_wind_speed(current.wind_speed)
    gusts_speed = current.wind_gust.to_f
    formatted_gusts = format_wind_speed(gusts_speed)

    text = []
    text << "#{beaufort_description(wind_speed_knots)} of #{formatted_wind_speed} from the #{direction.downcase}"
    text << "with #{formatted_gusts} gusts" if show_gusts?(current.wind_speed, gusts_speed)
    text.join(", ")
  end

  def current_aqi
    return if @air_quality&.aqi.blank?
    if @air_quality.aqi > 500
      "The air quality is so hazardous it's beyond the <abbr title=\"Air Quality Index\">AQI</abbr>"
    else
      "The air quality is #{@air_quality.category.downcase}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{@air_quality.aqi}"
    end
  end

  def format_pollen_level
    return if pollen_index_value(@pollen).zero?
    "Pollen levels are #{pollen_index_category(@pollen).downcase}"
  end

  def forecast
    text = []
    text << "#{today_or_tonight(@weather, @time_zone)}'s forecast #{format_forecasted_condition(rest_of_day.condition_code).downcase}"
    # This uses the readings that are available. Without the check, a day forecast with one of the
    # two values absent would read "with a high of  and a low of 12°C".
    temperatures = []
    temperatures << "a high of #{format_temperature(today.temperature_max)}" if !evening?(@weather, @time_zone) && today.temperature_max.present?
    temperatures << "a low of #{format_temperature(today.temperature_min)}" if today.temperature_min.present?
    text << "with #{temperatures.join(' and ')}" if temperatures.any?
    text.join(", ")
  end

  def precipitation
    precipitation_type = rest_of_day.precipitation_type.to_s.downcase
    chance = rest_of_day.precipitation_chance.to_f
    return if chance.zero? || precipitation_type.blank? || precipitation_type == "clear"

    snowfall = rest_of_day.snowfall_amount.to_f
    percentage_string = number_to_percentage(chance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(rest_of_day.precipitation_type)} later #{today_or_tonight(@weather, @time_zone).downcase}"
    text << "with #{format_precipitation_amount(snowfall)} expected" if precipitation_type == "snow" && snowfall > 0
    text.join(", ")
  end

  # ⚠️ The sun times are absent above the polar circles, and weather_data_is_current?, the check
  # that lets the rest of the summary use its data, does not test them. Remove the line, and do not
  # remove the full widget.
  # The name of the location, one time for each summary. Three sentences read it.
  # @return [String, nil]
  def location_name
    return @location_name if defined?(@location_name)

    @location_name = format_location(@location)
  end

  def sunrise_or_sunset
    now = Time.now
    todays_sunrise = sunrise(@weather, @time_zone)
    todays_sunset = sunset(@weather, @time_zone)
    return if todays_sunrise.blank? || todays_sunset.blank?

    # The exact times: "Sunset will be at 7:45" holds until 7:45, and not until 7:00.
    return "Sunrise will be at #{format_time(todays_sunrise)}" if now < todays_sunrise
    return "Sunset will be at #{format_time(todays_sunset)}" if now < todays_sunset

    tomorrow = tomorrows_sunrise(@weather, @time_zone)
    "Sunrise will be at #{format_time(tomorrow)}" if tomorrow.present?
  end

  def activities
    return unless daytime?(@weather, @time_zone)

    if race_day?(@events, @time_zone)
      return good_weather? ? "Good weather for racing!" : "Tough weather for racing!"
    end

    if indoor_season?
      return workout_scheduled?(@workouts) ? "It's a good day to train indoors!" : "It's a good day to rest!"
    end

    if workout_scheduled?(@workouts)
      if good_weather? && hot?
        return "It's a good day for some heat training!"
      elsif good_weather?
        return "It's a good day to train outside!"
      else
        return "It's a good day to train indoors!"
      end
    end

    good_weather? ? "It's a good day to be outside!" : "It's a good day to rest!"
  end

  def indoor_season?
    month = Time.current.in_time_zone(@time_zone).month
    in_jackson_hole?(@location) && (month <= 3 || month >= 11)
  end

  def bad_weather?
    current = current_weather(@weather)

    # The code changes the value and does not read a method on it. WeatherKit omits some fields,
    # for example the snowfall on a dry day and the gusts on some forecast days, and a field that is
    # absent must not stop the widget.
    aqi = @air_quality&.aqi.to_i
    current_temperature = (current.temperature_apparent || current.temperature).to_f
    high_temperature = today.temperature_max.to_f
    low_temperature = today.temperature_min.to_f
    precipitation_chance = rest_of_day.precipitation_chance.to_f
    snowfall = rest_of_day.snowfall_amount.to_f
    beaufort = beaufort_number(kph_to_knots(current.wind_speed.to_f))

    return true if aqi > 100
    return true if current_temperature <= -12 || current_temperature >= 35
    return true if low_temperature <= -12
    return true if high_temperature <= 0 || high_temperature >= 35
    return true if precipitation_chance >= 0.5
    return true if beaufort >= 4
    return true if snowfall > 0
    CONDITIONS.dig(current.condition_code&.to_sym, :adverse_weather) || CONDITIONS.dig(today.condition_code&.to_sym, :adverse_weather)
  end

  def good_weather?
    !bad_weather?
  end

  def hot?
    current = current_weather(@weather)
    current.temperature.to_f >= 30 || current.temperature_apparent.to_f >= 30
  end

  # With no apparent temperature there is nothing to show beside the true temperature. Thus the
  # code hides it and does not round a nil.
  def hide_apparent_temperature?
    current = current_weather(@weather)
    return true if current.temperature.blank? || current.temperature_apparent.blank?

    celsius_temp = current.temperature.round
    celsius_apparent = current.temperature_apparent.round
    fahrenheit_temp = celsius_to_fahrenheit(current.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(current.temperature_apparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end
end
