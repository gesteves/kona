# Builds the current-weather widget's prose summary — the business rules (is it good or bad
# weather, is it indoor season) and the sentence builders that compose it — keeping them out
# of the helper layer, which retains the thin formatting/selection methods (WeatherHelper).
# A plain object: it holds the request's weather data as its own state and passes it
# explicitly to the pure helper functions it composes.
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

  # For the non-block content_tag the formatting helpers build (units_tag, beaufort_description).
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

  # Both forecast selections linear-scan the daily forecast and re-parse two timestamps per day,
  # and several sentences ask for them. Memoized here — where the request's state already lives —
  # rather than in WeatherHelper, which is deliberately a set of pure functions over their
  # arguments.
  def today
    return @today if defined?(@today)
    @today = todays_forecast(@weather)
  end

  def rest_of_day
    return @rest_of_day if defined?(@rest_of_day)
    @rest_of_day = rest_of_day_forecast(@weather, @time_zone)
  end

  # The full composed summary as HTML (each sentence wrapped in a span).
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

  # The icon id for the current conditions (day/night-aware), for the widget's header.
  def icon
    weather_icon(current_weather(@weather)&.condition_code, :auto, weather: @weather, time_zone: @time_zone)
  end

  # The active weather alerts, deduped and sorted for display.
  def alerts
    weather_alerts(@weather)
  end

  def race_day
    "**It's race day!**" if race_day?(@events, @time_zone) && !evening?(@weather, @time_zone)
  end

  def current_location
    location = "I'm currently in **#{format_location(@location)}**"
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
    text = []
    text << "#{format_current_condition(current.condition_code).capitalize}, with a temperature of #{format_temperature(current.temperature)}"
    text << "which feels like #{format_temperature(current.temperature_apparent)}" unless hide_apparent_temperature?
    text << "#{number_to_percentage(current.humidity * 100, precision: 0)} humidity" unless current.humidity.blank? || current.humidity.zero?
    text << wind
    comma_join_with_and(text.compact)
  end

  def wind
    current = current_weather(@weather)
    direction = wind_direction(current.wind_direction)
    formatted_wind_speed = format_wind_speed(current.wind_speed)
    wind_speed_knots = kph_to_knots(current.wind_speed)

    gusts_speed = current&.wind_gust.to_f
    formatted_gusts = format_wind_speed(gusts_speed)

    return if direction.blank? || beaufort_number(wind_speed_knots).zero?

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
    if evening?(@weather, @time_zone)
      text << "with a low of #{format_temperature(today.temperature_min)}"
    else
      text << "with a high of #{format_temperature(today.temperature_max)} and a low of #{format_temperature(today.temperature_min)}"
    end
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

  # ⚠️ Sun times are genuinely absent above the polar circles, and weather_data_is_current? — the
  # gate that lets the rest of the summary assume its data — doesn't check them. Drop the line
  # rather than collapsing the whole widget over it.
  def sunrise_or_sunset
    now = Time.now
    todays_sunrise = sunrise(@weather, @time_zone)
    todays_sunset = sunset(@weather, @time_zone)
    return if todays_sunrise.blank? || todays_sunset.blank?

    return "Sunrise will be at #{format_time(todays_sunrise)}" if now <= todays_sunrise.beginning_of_hour
    return "Sunset will be at #{format_time(todays_sunset)}" if now >= todays_sunrise.beginning_of_hour && now < todays_sunset.beginning_of_hour

    tomorrow = tomorrows_sunrise(@weather, @time_zone)
    return "Sunrise will be at #{format_time(tomorrow)}" if tomorrow.present? && now >= todays_sunset.beginning_of_hour
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
    in_jackson_hole?(@location) && (Time.now.month <= 3 || Time.now.month >= 11)
  end

  def bad_weather?
    current = current_weather(@weather)

    # Coerced rather than dereferenced: WeatherKit omits individual fields (snowfall on a dry
    # day, gusts on some forecast days), and a missing one must not take the widget down.
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

  # With no apparent temperature there's nothing to show alongside the real one, so hide it
  # rather than rounding a nil.
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
