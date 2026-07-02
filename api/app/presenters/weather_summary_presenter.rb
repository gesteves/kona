# Builds the current-weather widget's prose summary — the business rules (is it good or bad
# weather, is it indoor season) and the sentence builders that compose it — keeping them out
# of the helper layer, which retains the thin formatting/selection methods (WeatherHelper).
# Follows the EventWeatherPresenter pattern: a plain object that includes the helpers it
# composes and holds the request's weather data. Ported from the prose half of the former
# 400-line WeatherHelper.
class WeatherSummaryPresenter
  include WeatherHelper   # forecast selection + condition/temperature/wind formatting
  include MarkupHelper    # units_tag
  include UnitsHelper     # unit conversions + ActiveSupport::NumberHelper
  include TimeHelper      # location_time_zone / current_time
  include TextHelper      # comma_join_with_and / with_indefinite_article / remove_widows
  include MarkdownHelper  # markdown_to_html for the composed summary
  include WorkoutsHelper  # is_workout_scheduled?
  include EventsHelper    # todays_race / is_race_day?
  include LocationHelper  # format_location / format_elevation / in_jackson_hole?
  include BayHelper       # bay_water_temperature_sentence

  # content_tag with a block (beaufort_description) needs capture + an output buffer.
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::CaptureHelper
  attr_accessor :output_buffer

  # The included helpers read the same ivars the controller exposes to the view.
  def initialize(weather: nil, location: nil, air_quality: nil, pollen: nil, events: nil, goodspeed: nil, workouts: nil, time_zone: nil)
    @weather = weather
    @location = location
    @air_quality = air_quality
    @pollen = pollen
    @events = events
    @goodspeed = goodspeed
    @workouts = workouts
    @time_zone = time_zone
  end

  # The full composed summary as HTML (each sentence wrapped in a span).
  def weather_summary
    summary = []
    summary << race_day
    summary << smooth
    summary << current_location
    summary << elevation
    summary << currently
    summary << bay_water_temperature_sentence
    summary << current_aqi
    summary << format_pollen_level
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{t}</span>" }.join(" "))
  end

  def race_day
    "**It's race day!**" if is_race_day? && !is_evening?
  end

  def current_location
    location = "I'm currently in **#{format_location}**"
    the = todays_race&.title&.downcase&.start_with?("ironman") ? "" : "the"
    location << ", racing #{the} **#{todays_race.title}**" if is_race_day? && !is_evening?
    location
  end

  def elevation
    return if format_elevation.blank?
    "The elevation is #{format_elevation}"
  end

  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot? && is_daytime?
  end

  def currently
    text = []
    text << "#{format_current_condition(current_weather.condition_code).capitalize}, with a temperature of #{format_temperature(current_weather.temperature)}"
    text << "which feels like #{format_temperature(current_weather.temperature_apparent)}" unless hide_apparent_temperature?
    text << "#{number_to_percentage(current_weather.humidity * 100, precision: 0)} humidity" unless current_weather.humidity.blank? || current_weather.humidity.zero?
    text << wind
    comma_join_with_and(text.compact)
  end

  def wind
    direction = wind_direction(current_weather.wind_direction)
    formatted_wind_speed = format_wind_speed(current_weather.wind_speed)
    wind_speed_knots = kph_to_knots(current_weather.wind_speed)

    gusts_speed = current_weather&.wind_gust.to_f
    formatted_gusts = format_wind_speed(gusts_speed)

    return if direction.blank? || beaufort_number(wind_speed_knots).zero?

    text = []
    text << "#{beaufort_description(wind_speed_knots)} of #{formatted_wind_speed} from the #{direction.downcase}"
    text << "with #{formatted_gusts} gusts" if show_gusts?(current_weather.wind_speed, gusts_speed)
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
    return if pollen_index_value.zero?
    "Pollen levels are #{pollen_index_category.downcase}"
  end

  def forecast
    text = []
    text << "#{today_or_tonight}'s forecast #{format_forecasted_condition(rest_of_day_forecast.condition_code).downcase}"
    if is_evening?
      text << "with a low of #{format_temperature(todays_forecast.temperature_min)}"
    else
      text << "with a high of #{format_temperature(todays_forecast.temperature_max)} and a low of #{format_temperature(todays_forecast.temperature_min)}"
    end
    text.join(", ")
  end

  def precipitation
    return if rest_of_day_forecast.precipitation_chance == 0 || rest_of_day_forecast.precipitation_type.downcase == "clear"
    percentage_string = number_to_percentage(rest_of_day_forecast.precipitation_chance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(rest_of_day_forecast.precipitation_type)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(rest_of_day_forecast.snowfall_amount)} expected" if rest_of_day_forecast.precipitation_type.downcase == "snow" && rest_of_day_forecast.snowfall_amount > 0
    text.join(", ")
  end

  def sunrise_or_sunset
    now = Time.now
    return "Sunrise will be at #{format_time(sunrise)}" if now <= sunrise.beginning_of_hour
    return "Sunset will be at #{format_time(sunset)}" if now >= sunrise.beginning_of_hour && now < sunset.beginning_of_hour
    return "Sunrise will be at #{format_time(tomorrows_sunrise)}" if now >= sunset.beginning_of_hour
  end

  def activities
    return unless is_daytime?

    if is_race_day?
      return is_good_weather? ? "Good weather for racing!" : "Tough weather for racing!"
    end

    if is_indoor_season?
      return is_workout_scheduled? ? "It's a good day to train indoors!" : "It's a good day to rest!"
    end

    if is_workout_scheduled?
      if is_good_weather? && is_hot?
        return "It's a good day for some heat training!"
      elsif is_good_weather?
        return "It's a good day to train outside!"
      else
        return "It's a good day to train indoors!"
      end
    end

    is_good_weather? ? "It's a good day to be outside!" : "It's a good day to rest!"
  end

  def is_indoor_season?
    in_jackson_hole? && (Time.now.month <= 3 || Time.now.month >= 11)
  end

  def is_bad_weather?
    aqi = @air_quality&.aqi.to_i
    current_temperature = (current_weather.temperature_apparent || current_weather.temperature)
    high_temperature = todays_forecast.temperature_max
    low_temperature = todays_forecast.temperature_min
    precipitation_chance = rest_of_day_forecast.precipitation_chance
    snowfall = rest_of_day_forecast.snowfall_amount
    beaufort = beaufort_number(kph_to_knots(current_weather.wind_speed))

    return true if aqi > 100
    return true if current_temperature <= -12 || current_temperature >= 35
    return true if low_temperature <= -12
    return true if high_temperature <= 0 || high_temperature >= 35
    return true if precipitation_chance >= 0.5
    return true if beaufort >= 4
    return true if snowfall > 0
    CONDITIONS.dig(current_weather.condition_code&.to_sym, :adverse_weather) || CONDITIONS.dig(todays_forecast.condition_code&.to_sym, :adverse_weather)
  end

  def is_good_weather?
    !is_bad_weather?
  end

  def is_hot?
    current_weather.temperature >= 30 || current_weather.temperature_apparent >= 30
  end

  def hide_apparent_temperature?
    celsius_temp = current_weather.temperature.round
    celsius_apparent = current_weather.temperature_apparent.round
    fahrenheit_temp = celsius_to_fahrenheit(current_weather.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(current_weather.temperature_apparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end
end
