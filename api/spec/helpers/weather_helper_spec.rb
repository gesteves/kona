require "rails_helper"

# Coverage for the weather helper. The narrative bits — the weather summary, the race-day
# sentences, the "is it daytime / evening" logic, and the good-vs-bad weather call — are the
# hard parts, so they get the most attention here.
#
# Most tests build a `@weather` fixture whose forecast window and sunrise/sunset are expressed
# as offsets from the current time, so they're self-consistent without freezing the clock. The
# no-forecast daytime/evening fallback reads the wall clock in the location's timezone
# (`@time_zone`), so it freezes a fixed UTC instant and asserts against the Denver-local hour.
# The indoor-season month check uses `travel_to(Time.now.change(...))` so the month is
# deterministic regardless of where the suite runs.
#
# Cross-domain predicates the summary leans on (`is_race_day?`, `todays_race`, `format_location`,
# `format_elevation`, `is_workout_scheduled?`, …) live in sibling helpers with their own specs,
# so they're stubbed here to keep these tests about the weather logic.
RSpec.describe WeatherHelper, type: :helper do
  include ActiveSupport::Testing::TimeHelpers

  before { helper.instance_variable_set(:@time_zone, "America/Denver") }

  # Builds and assigns a @weather fixture. `current`, `today`, `rest_of_day`, and `overnight`
  # are merged into the respective sub-hashes; `sunrise`/`sunset` override today's sun times.
  def build_weather(current: {}, today: {}, rest_of_day: {}, overnight: {}, sunrise: nil, sunset: nil, alerts: [])
    now = Time.current
    weather = DeepOstruct.wrap(
      current_weather: {
        condition_code: "PartlyCloudy",
        temperature: 18.4,
        temperature_apparent: 17.9,
        humidity: 0.55,
        wind_speed: 12.0,
        wind_direction: 270,
        wind_gust: 18.0
      }.merge(current),
      forecast_daily: {
        days: [
          {
            forecast_start: (now - 6.hours).iso8601,
            forecast_end: (now + 18.hours).iso8601,
            condition_code: "PartlyCloudy",
            temperature_max: 24.0,
            temperature_min: 11.0,
            sunrise: (sunrise || (now - 5.hours)).iso8601,
            sunset: (sunset || (now + 5.hours)).iso8601,
            rest_of_day_forecast: { condition_code: "Clear", precipitation_chance: 0.1, precipitation_type: "clear", snowfall_amount: 0 }.merge(rest_of_day),
            overnight_forecast: { condition_code: "Clear", precipitation_chance: 0.0, precipitation_type: "clear", snowfall_amount: 0 }.merge(overnight)
          }.merge(today),
          {
            forecast_start: (now + 18.hours).iso8601,
            forecast_end: (now + 42.hours).iso8601,
            condition_code: "Clear",
            temperature_max: 22.0,
            temperature_min: 10.0,
            sunrise: (now + 19.hours).iso8601,
            sunset: (now + 29.hours).iso8601,
            rest_of_day_forecast: { condition_code: "Clear", precipitation_chance: 0.0, precipitation_type: "clear", snowfall_amount: 0 }
          }
        ]
      },
      weather_alerts: { alerts: alerts }
    )
    helper.instance_variable_set(:@weather, weather)
    weather
  end

  # ---------------------------------------------------------------------------
  # Condition phrases
  # ---------------------------------------------------------------------------
  describe "condition phrasing" do
    it "looks up the current/forecast/simplified phrases from CONDITIONS" do
      expect(helper.format_current_condition("Clear")).to eq("it's clear")
      expect(helper.format_forecasted_condition("Clear")).to eq("is clear")
      expect(helper.format_condition("Clear")).to eq("Clear")
    end

    it "falls back to a humanized phrase for unknown codes" do
      expect(helper.format_current_condition("SomethingNew")).to eq("it's something new")
      expect(helper.format_forecasted_condition("SomethingNew")).to eq("calls for something new")
      expect(helper.format_condition("SomethingNew")).to eq("something new")
    end
  end

  # ---------------------------------------------------------------------------
  # Number / unit formatting
  # ---------------------------------------------------------------------------
  describe "#format_temperature" do
    it "renders both Celsius and Fahrenheit with the unit toggle" do
      html = helper.format_temperature(18.0)
      expect(html).to include("18ºC")
      expect(html).to include('data-units-imperial-value="64ºF"')
    end
  end

  describe "#format_precipitation_amount" do
    it "describes tiny amounts as less than a centimeter / inch" do
      html = helper.format_precipitation_amount(5)
      expect(html).to include("less than a centimeter")
      expect(html).to include('data-units-imperial-value="less than an inch"')
    end

    it "describes larger amounts approximately in both systems" do
      html = helper.format_precipitation_amount(60)
      expect(html).to include("about")
      expect(html).to match(/inch/)
    end
  end

  describe "#format_precipitation_type" do
    it "renames clear to precipitation and mixed to wintry mix, else downcases" do
      expect(helper.format_precipitation_type("Clear")).to eq("precipitation")
      expect(helper.format_precipitation_type("Mixed")).to eq("wintry mix")
      expect(helper.format_precipitation_type("Snow")).to eq("snow")
    end
  end

  describe "#format_wind_speed / #format_wind_speed_range" do
    it "formats a single speed in km/h and mph" do
      html = helper.format_wind_speed(20)
      expect(html).to include("20 km/h")
      expect(html).to include('data-units-imperial-value="12 mph"')
    end

    it "returns nil when both ends of a range are blank" do
      expect(helper.format_wind_speed_range(nil, nil)).to be_nil
    end

    it "collapses an equal range to a single value" do
      expect(helper.format_wind_speed_range(20, 20)).to include("20 km/h")
    end

    it "renders a dash-separated range when the ends differ" do
      expect(helper.format_wind_speed_range(10, 20)).to include("10–20 km/h")
    end
  end

  describe "#format_time" do
    it "formats the time and wraps the meridiem in an abbr" do
      time = Time.zone.parse("2026-06-15 09:05:00")
      expect(helper.format_time(time)).to include("9:05&nbsp;<abbr>AM</abbr>")
    end
  end

  describe "#wind_direction" do
    it "maps degrees to a cardinal direction" do
      expect(helper.wind_direction(0)).to eq("North")
      expect(helper.wind_direction(45)).to eq("Northeast")
      expect(helper.wind_direction(90)).to eq("East")
      expect(helper.wind_direction(180)).to eq("South")
      expect(helper.wind_direction(270)).to eq("West")
      expect(helper.wind_direction(350)).to eq("North")
    end

    it "abbreviates when asked" do
      expect(helper.wind_direction(270, true)).to eq("W")
      expect(helper.wind_direction(45, true)).to eq("NE")
    end
  end

  describe "#beaufort_number / #beaufort_description" do
    it "scales knots to a 0–12 Beaufort number, clamped" do
      expect(helper.beaufort_number(0)).to eq(0)
      expect(helper.beaufort_number(1.625)).to eq(1)
      expect(helper.beaufort_number(200)).to eq(12)
    end

    it "describes the Beaufort level in a titled span" do
      html = helper.beaufort_description(0)
      expect(html).to include('title="Beaufort scale 0"')
      expect(html).to include("no wind")
    end
  end

  describe "#show_gusts?" do
    it "is true only for strong gusts well above the sustained wind" do
      expect(helper.show_gusts?(10, 40)).to be(true)
      expect(helper.show_gusts?(10, 12)).to be(false)
    end
  end

  describe "#aqi_icon" do
    it "picks an icon by AQI band" do
      expect(helper.aqi_icon(30)).to eq("sun-haze")
      expect(helper.aqi_icon(100)).to eq("smog")
      expect(helper.aqi_icon(175)).to eq("smoke")
      expect(helper.aqi_icon(300)).to eq("fire-smoke")
    end
  end

  # ---------------------------------------------------------------------------
  # Pollen
  # ---------------------------------------------------------------------------
  describe "pollen" do
    it "reports the highest non-zero index and its category" do
      helper.instance_variable_set(:@pollen, DeepOstruct.wrap(pollen_type_info: [
        { index_info: { value: 1, category: "Low" } },
        { index_info: { value: 3, category: "Moderate" } }
      ]))

      expect(helper.pollen_index_value).to eq(3)
      expect(helper.pollen_index_category).to eq("Moderate")
      expect(helper.format_pollen_level).to eq("Pollen levels are moderate")
    end

    it "treats all-zero (or missing) pollen as None and emits no sentence" do
      helper.instance_variable_set(:@pollen, DeepOstruct.wrap(pollen_type_info: [{ index_info: { value: 0, category: "None" } }]))

      expect(helper.pollen_index_value).to eq(0)
      expect(helper.pollen_index_category).to eq("None")
      expect(helper.format_pollen_level).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Weather data presence
  # ---------------------------------------------------------------------------
  describe "weather data presence" do
    it "exposes current weather and today's forecast and reports currency" do
      build_weather
      expect(helper.current_weather.condition_code).to eq("PartlyCloudy")
      expect(helper.todays_forecast.temperature_max).to eq(24.0)
      expect(helper.weather_data_is_current?).to be(true)
      expect(helper.weather_data_is_stale?).to be(false)
    end

    it "is stale when there's no weather" do
      expect(helper.weather_data_is_current?).to be(false)
      expect(helper.weather_data_is_stale?).to be(true)
    end

    it "returns the daytime forecast during the day and the overnight one in the evening" do
      build_weather(rest_of_day: { condition_code: "Rain" }, overnight: { condition_code: "Cloudy" })

      allow(helper).to receive(:is_evening?).and_return(false)
      expect(helper.rest_of_day_forecast.condition_code).to eq("Rain")

      allow(helper).to receive(:is_evening?).and_return(true)
      expect(helper.rest_of_day_forecast.condition_code).to eq("Cloudy")
    end

    it "finds tomorrow's forecast" do
      build_weather
      expect(helper.tomorrows_forecast.temperature_max).to eq(22.0)
    end
  end

  # ---------------------------------------------------------------------------
  # Time of day
  # ---------------------------------------------------------------------------
  describe "#is_daytime? / #is_evening?" do
    it "is daytime between sunrise and sunset" do
      build_weather # sunrise 5h ago, sunset in 5h
      expect(helper.is_daytime?).to be(true)
      expect(helper.is_evening?).to be(false)
    end

    it "is evening (and not daytime) once the sun has set" do
      build_weather(sunset: Time.current - 1.hour)
      expect(helper.is_daytime?).to be(false)
      expect(helper.is_evening?).to be(true)
    end

    it "falls back to clock hours in the location's timezone when there's no weather" do
      # @time_zone is America/Denver (UTC-6 in June), so the fallback reads the Denver-local
      # hour, not the machine's. 18:00 UTC == 12:00 MDT (daytime).
      travel_to(Time.utc(2026, 6, 3, 18, 0, 0)) do
        expect(helper.is_daytime?).to be(true)
        expect(helper.is_evening?).to be(false)
      end

      # 04:00 UTC == 22:00 MDT the previous evening.
      travel_to(Time.utc(2026, 6, 4, 4, 0, 0)) do
        expect(helper.is_daytime?).to be(false)
        expect(helper.is_evening?).to be(true)
      end
    end

    it "says Today during the day and Tonight in the evening" do
      build_weather
      expect(helper.today_or_tonight).to eq("Today")

      build_weather(sunset: Time.current - 1.hour)
      expect(helper.today_or_tonight).to eq("Tonight")
    end
  end

  describe "#sunrise / #sunset / #tomorrows_sunrise" do
    it "returns zoned times from the forecast" do
      build_weather
      expect(helper.sunrise).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.sunset).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.tomorrows_sunrise).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.tomorrows_sunrise).to be > helper.sunrise
    end
  end

  # ---------------------------------------------------------------------------
  # Weather quality
  # ---------------------------------------------------------------------------
  describe "#is_hot?" do
    it "is hot at or above 30º for either actual or apparent temperature" do
      build_weather(current: { temperature: 31.0, temperature_apparent: 28.0 })
      expect(helper.is_hot?).to be(true)
    end

    it "is not hot on a mild day" do
      build_weather
      expect(helper.is_hot?).to be(false)
    end
  end

  describe "#hide_apparent_temperature?" do
    it "hides the feels-like when it rounds to the same value" do
      build_weather(current: { temperature: 18.0, temperature_apparent: 18.4 })
      expect(helper.hide_apparent_temperature?).to be(true)
    end

    it "shows the feels-like when it differs" do
      build_weather(current: { temperature: 18.0, temperature_apparent: 12.0 })
      expect(helper.hide_apparent_temperature?).to be(false)
    end
  end

  describe "#is_bad_weather? / #is_good_weather?" do
    it "is good weather on a mild, calm, clear day" do
      build_weather
      expect(helper.is_good_weather?).to be(true)
      expect(helper.is_bad_weather?).to be(false)
    end

    it "is bad when the air quality is unhealthy" do
      build_weather
      helper.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 150, category: "Unhealthy"))
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad in dangerous heat (by apparent temperature)" do
      build_weather(current: { temperature_apparent: 36.0 })
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad when the forecast high is freezing or scorching" do
      build_weather(today: { temperature_max: 36.0 })
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad when rain is likely" do
      build_weather(rest_of_day: { precipitation_chance: 0.6 })
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad when it's windy" do
      build_weather(current: { wind_speed: 45.0 })
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad when snow is expected" do
      build_weather(rest_of_day: { precipitation_type: "snow", snowfall_amount: 5 })
      expect(helper.is_bad_weather?).to be(true)
    end

    it "is bad under an adverse current condition" do
      build_weather(current: { condition_code: "Blizzard" })
      expect(helper.is_bad_weather?).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Race-day sentences
  # ---------------------------------------------------------------------------
  describe "#race_day" do
    it "announces race day during the day" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_evening?).and_return(false)
      expect(helper.race_day).to eq("**It's race day!**")
    end

    it "says nothing in the evening or on a non-race day" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_evening?).and_return(true)
      expect(helper.race_day).to be_nil

      allow(helper).to receive(:is_race_day?).and_return(false)
      allow(helper).to receive(:is_evening?).and_return(false)
      expect(helper.race_day).to be_nil
    end
  end

  describe "#current_location" do
    before { allow(helper).to receive(:format_location).and_return("Boulder, Colorado") }

    it "states the location with no race mention off race day" do
      allow(helper).to receive(:is_race_day?).and_return(false)
      expect(helper.current_location).to eq("I'm currently in **Boulder, Colorado**")
    end

    it "adds the race with a definite article on race day" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_evening?).and_return(false)
      allow(helper).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Boston Marathon"))
      expect(helper.current_location).to eq("I'm currently in **Boulder, Colorado**, racing the **Boston Marathon**")
    end

    it "drops the article for Ironman races" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_evening?).and_return(false)
      allow(helper).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Ironman World Championship"))
      result = helper.current_location
      expect(result).to include("**Ironman World Championship**")
      expect(result).not_to include("racing the")
    end
  end

  describe "#elevation" do
    it "states the elevation when known, otherwise nothing" do
      allow(helper).to receive(:format_elevation).and_return("1,655 m")
      expect(helper.elevation).to eq("The elevation is 1,655 m")

      allow(helper).to receive(:format_elevation).and_return(nil)
      expect(helper.elevation).to be_nil
    end
  end

  describe "#smooth" do
    it "quips on a hot non-race daytime" do
      allow(helper).to receive(:is_race_day?).and_return(false)
      allow(helper).to receive(:is_hot?).and_return(true)
      allow(helper).to receive(:is_daytime?).and_return(true)
      expect(helper.smooth).to eq("Man, it's a hot one!")
    end

    it "stays quiet on race day" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_hot?).and_return(true)
      allow(helper).to receive(:is_daytime?).and_return(true)
      expect(helper.smooth).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Current conditions / wind / AQI / forecast / precipitation
  # ---------------------------------------------------------------------------
  describe "#currently" do
    it "summarizes condition, temperature, humidity and wind, hiding a matching feels-like" do
      build_weather(current: { temperature: 18.4, temperature_apparent: 17.9, humidity: 0.55 })
      text = helper.currently
      expect(text).to include("It's partly cloudy, with a temperature of")
      expect(text).to include("55% humidity")
      expect(text).not_to include("which feels like")
    end

    it "includes the feels-like when it differs" do
      build_weather(current: { temperature: 25.0, temperature_apparent: 30.0 })
      expect(helper.currently).to include("which feels like")
    end
  end

  describe "#wind" do
    it "describes the Beaufort strength, speed and direction" do
      build_weather(current: { wind_speed: 20.0, wind_direction: 270, wind_gust: 22.0 })
      text = helper.wind
      expect(text).to include("from the west")
      expect(text).to include("km/h")
    end

    it "is silent when the air is calm" do
      build_weather(current: { wind_speed: 0.0, wind_direction: 270 })
      expect(helper.wind).to be_nil
    end

    it "mentions gusts when they're notably stronger" do
      build_weather(current: { wind_speed: 15.0, wind_direction: 270, wind_gust: 50.0 })
      expect(helper.wind).to include("gusts")
    end
  end

  describe "#current_aqi" do
    it "is silent without air quality data" do
      expect(helper.current_aqi).to be_nil
    end

    it "describes a normal AQI reading" do
      helper.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 42, category: "Good"))
      expect(helper.current_aqi).to include("The air quality is good, with an")
      expect(helper.current_aqi).to include("AQI</abbr> of 42")
    end

    it "flags readings beyond the scale" do
      helper.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 600, category: "Hazardous"))
      expect(helper.current_aqi).to include("beyond the")
    end
  end

  describe "#forecast" do
    it "gives a high and low during the day" do
      build_weather
      allow(helper).to receive(:is_evening?).and_return(false)
      text = helper.forecast
      expect(text).to include("Today's forecast is clear")
      expect(text).to include("with a high of")
      expect(text).to include("and a low of")
    end

    it "gives only a low in the evening" do
      build_weather(overnight: { condition_code: "Clear" })
      allow(helper).to receive(:is_evening?).and_return(true)
      text = helper.forecast
      expect(text).to include("Tonight's forecast is clear")
      expect(text).to include("with a low of")
      expect(text).not_to include("high of")
    end
  end

  describe "#precipitation" do
    it "is silent when there's no chance, or it's clear" do
      build_weather(rest_of_day: { precipitation_chance: 0, precipitation_type: "clear" })
      expect(helper.precipitation).to be_nil
    end

    it "states the chance of rain later today" do
      build_weather(rest_of_day: { precipitation_chance: 0.4, precipitation_type: "rain" })
      allow(helper).to receive(:is_evening?).and_return(false)
      expect(helper.precipitation).to include("chance of rain later today")
    end

    it "adds an expected amount for snow" do
      build_weather(rest_of_day: { precipitation_chance: 0.5, precipitation_type: "snow", snowfall_amount: 30 })
      allow(helper).to receive(:is_evening?).and_return(false)
      text = helper.precipitation
      expect(text).to include("chance of snow")
      expect(text).to include("expected")
    end
  end

  describe "#sunrise_or_sunset" do
    it "counts down to sunrise before it happens" do
      build_weather(sunrise: Time.current + 2.hours, sunset: Time.current + 8.hours)
      expect(helper.sunrise_or_sunset).to include("Sunrise will be at")
    end

    it "counts down to sunset during the day" do
      build_weather
      expect(helper.sunrise_or_sunset).to include("Sunset will be at")
    end

    it "counts down to tomorrow's sunrise after sunset" do
      build_weather(sunrise: Time.current - 8.hours, sunset: Time.current - 1.hour)
      expect(helper.sunrise_or_sunset).to include("Sunrise will be at")
    end
  end

  # ---------------------------------------------------------------------------
  # Activity suggestions
  # ---------------------------------------------------------------------------
  describe "#activities" do
    before do
      allow(helper).to receive(:is_daytime?).and_return(true)
      allow(helper).to receive(:is_race_day?).and_return(false)
      allow(helper).to receive(:is_indoor_season?).and_return(false)
      allow(helper).to receive(:is_workout_scheduled?).and_return(false)
      allow(helper).to receive(:is_good_weather?).and_return(true)
      allow(helper).to receive(:is_hot?).and_return(false)
    end

    it "says nothing at night" do
      allow(helper).to receive(:is_daytime?).and_return(false)
      expect(helper.activities).to be_nil
    end

    it "calls the racing weather on race day" do
      allow(helper).to receive(:is_race_day?).and_return(true)
      expect(helper.activities).to eq("Good weather for racing!")

      allow(helper).to receive(:is_good_weather?).and_return(false)
      expect(helper.activities).to eq("Tough weather for racing!")
    end

    it "suggests indoor training or rest during indoor season" do
      allow(helper).to receive(:is_indoor_season?).and_return(true)

      allow(helper).to receive(:is_workout_scheduled?).and_return(true)
      expect(helper.activities).to eq("It's a good day to train indoors!")

      allow(helper).to receive(:is_workout_scheduled?).and_return(false)
      expect(helper.activities).to eq("It's a good day to rest!")
    end

    it "tailors a scheduled workout to the weather" do
      allow(helper).to receive(:is_workout_scheduled?).and_return(true)

      allow(helper).to receive(:is_hot?).and_return(true)
      expect(helper.activities).to eq("It's a good day for some heat training!")

      allow(helper).to receive(:is_hot?).and_return(false)
      expect(helper.activities).to eq("It's a good day to train outside!")

      allow(helper).to receive(:is_good_weather?).and_return(false)
      expect(helper.activities).to eq("It's a good day to train indoors!")
    end

    it "falls back to outside / rest with no workout scheduled" do
      expect(helper.activities).to eq("It's a good day to be outside!")

      allow(helper).to receive(:is_good_weather?).and_return(false)
      expect(helper.activities).to eq("It's a good day to rest!")
    end
  end

  describe "#is_indoor_season?" do
    it "is true only in Jackson Hole during the winter months" do
      allow(helper).to receive(:in_jackson_hole?).and_return(true)

      travel_to(Time.now.change(month: 12)) { expect(helper.is_indoor_season?).to be(true) }
      travel_to(Time.now.change(month: 7)) { expect(helper.is_indoor_season?).to be(false) }
    end

    it "is false away from Jackson Hole even in winter" do
      allow(helper).to receive(:in_jackson_hole?).and_return(false)
      travel_to(Time.now.change(month: 12)) { expect(helper.is_indoor_season?).to be(false) }
    end
  end

  # ---------------------------------------------------------------------------
  # Icon + alerts
  # ---------------------------------------------------------------------------
  describe "#weather_icon" do
    it "returns a single string icon directly" do
      expect(helper.weather_icon("Cloudy")).to eq("clouds")
    end

    it "picks day vs night for icons that have both" do
      expect(helper.weather_icon("Clear", :day)).to eq("sun")
      expect(helper.weather_icon("Clear", :night)).to eq("moon-stars")
    end

    it "auto-selects by daytime" do
      allow(helper).to receive(:is_daytime?).and_return(true)
      expect(helper.weather_icon("Clear", :auto)).to eq("sun")
      allow(helper).to receive(:is_daytime?).and_return(false)
      expect(helper.weather_icon("Clear", :auto)).to eq("moon-stars")
    end

    it "falls back to a question-mark cloud for unknown conditions" do
      expect(helper.weather_icon("Nonsense")).to eq("cloud-question")
    end

    it "defaults to the current condition's icon" do
      build_weather(current: { condition_code: "Cloudy" })
      expect(helper.weather_icon).to eq("clouds")
    end
  end

  describe "#weather_alerts" do
    it "is empty without alerts" do
      build_weather
      expect(helper.weather_alerts).to eq([])
    end

    it "keeps the lowest-precedence alert per token, sorted by precedence" do
      build_weather(alerts: [
        { token: "flood", precedence: 3, description: "Flood B" },
        { token: "flood", precedence: 1, description: "Flood A" },
        { token: "heat", precedence: 5, description: "Heat" }
      ])

      alerts = helper.weather_alerts
      expect(alerts.map(&:description)).to eq(["Flood A", "Heat"])
    end
  end

  # ---------------------------------------------------------------------------
  # Full summary (integration of the pieces above)
  # ---------------------------------------------------------------------------
  describe "#weather_summary" do
    before do
      build_weather
      allow(helper).to receive(:is_race_day?).and_return(true)
      allow(helper).to receive(:is_evening?).and_return(false)
      allow(helper).to receive(:is_daytime?).and_return(true)
      allow(helper).to receive(:is_good_weather?).and_return(true)
      allow(helper).to receive(:is_workout_scheduled?).and_return(false)
      allow(helper).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Boston Marathon"))
      allow(helper).to receive(:format_location).and_return("Boston, Massachusetts")
      allow(helper).to receive(:format_elevation).and_return("43 m")
    end

    it "stitches the sentences into wrapped HTML spans" do
      html = helper.weather_summary
      expect(html).to include("<span>")
      expect(html).to include("race day")                # race_day note (smartypants-ified)
      expect(html).to include("Boston, Massachusetts")   # current_location
      expect(html).to include("racing the")              # racing the Boston Marathon
      expect(html).to include("temperature of")          # currently
      expect(html).to include("Good weather for racing!") # activities
    end

    it "omits the race-day note and racing clause off race day" do
      allow(helper).to receive(:is_race_day?).and_return(false)
      html = helper.weather_summary
      expect(html).not_to include("race day")
      expect(html).not_to include("racing")
    end
  end
end
