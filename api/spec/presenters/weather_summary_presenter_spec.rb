require "rails_helper"

# Coverage for the weather-summary prose: the sentence builders, the good-vs-bad weather
# call, and the activity suggestions (moved here from WeatherHelper — the thin selection/
# formatting methods stay covered in weather_helper_spec).
#
# Most tests build a `@weather` fixture whose forecast window and sunrise/sunset are expressed
# as offsets from the current time, so they're self-consistent without freezing the clock. The
# indoor-season month check uses `travel_to(Time.now.change(...))` so the month is
# deterministic regardless of where the suite runs.
#
# Cross-domain predicates the summary leans on (`is_race_day?`, `todays_race`, `format_location`,
# `format_elevation`, `is_workout_scheduled?`, …) come from the included helpers with their own
# specs, so they're stubbed here to keep these tests about the prose logic.
RSpec.describe WeatherSummaryPresenter do
  include ActiveSupport::Testing::TimeHelpers

  subject(:presenter) { described_class.new(time_zone: "America/Denver") }

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
    presenter.instance_variable_set(:@weather, weather)
    weather
  end

  # ---------------------------------------------------------------------------
  # Weather quality
  # ---------------------------------------------------------------------------
  describe "#is_hot?" do
    it "is hot at or above 30° for either actual or apparent temperature" do
      build_weather(current: { temperature: 31.0, temperature_apparent: 28.0 })
      expect(presenter.is_hot?).to be(true)
    end

    it "is not hot on a mild day" do
      build_weather
      expect(presenter.is_hot?).to be(false)
    end
  end

  describe "#hide_apparent_temperature?" do
    it "hides the feels-like when it rounds to the same value" do
      build_weather(current: { temperature: 18.0, temperature_apparent: 18.4 })
      expect(presenter.hide_apparent_temperature?).to be(true)
    end

    it "shows the feels-like when it differs" do
      build_weather(current: { temperature: 18.0, temperature_apparent: 12.0 })
      expect(presenter.hide_apparent_temperature?).to be(false)
    end
  end

  describe "#is_bad_weather? / #is_good_weather?" do
    it "is good weather on a mild, calm, clear day" do
      build_weather
      expect(presenter.is_good_weather?).to be(true)
      expect(presenter.is_bad_weather?).to be(false)
    end

    it "is bad when the air quality is unhealthy" do
      build_weather
      presenter.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 150, category: "Unhealthy"))
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad in dangerous heat (by apparent temperature)" do
      build_weather(current: { temperature_apparent: 36.0 })
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad when the forecast high is freezing or scorching" do
      build_weather(today: { temperature_max: 36.0 })
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad when rain is likely" do
      build_weather(rest_of_day: { precipitation_chance: 0.6 })
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad when it's windy" do
      build_weather(current: { wind_speed: 45.0 })
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad when snow is expected" do
      build_weather(rest_of_day: { precipitation_type: "snow", snowfall_amount: 5 })
      expect(presenter.is_bad_weather?).to be(true)
    end

    it "is bad under an adverse current condition" do
      build_weather(current: { condition_code: "Blizzard" })
      expect(presenter.is_bad_weather?).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  # Race-day sentences
  # ---------------------------------------------------------------------------
  describe "#race_day" do
    it "announces race day during the day" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_evening?).and_return(false)
      expect(presenter.race_day).to eq("**It's race day!**")
    end

    it "says nothing in the evening or on a non-race day" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_evening?).and_return(true)
      expect(presenter.race_day).to be_nil

      allow(presenter).to receive(:is_race_day?).and_return(false)
      allow(presenter).to receive(:is_evening?).and_return(false)
      expect(presenter.race_day).to be_nil
    end
  end

  describe "#current_location" do
    before { allow(presenter).to receive(:format_location).and_return("Boulder, Colorado") }

    it "states the location with no race mention off race day" do
      allow(presenter).to receive(:is_race_day?).and_return(false)
      expect(presenter.current_location).to eq("I'm currently in **Boulder, Colorado**")
    end

    it "adds the race with a definite article on race day" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_evening?).and_return(false)
      allow(presenter).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Boston Marathon"))
      expect(presenter.current_location).to eq("I'm currently in **Boulder, Colorado**, racing the **Boston Marathon**")
    end

    it "drops the article for Ironman races" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_evening?).and_return(false)
      allow(presenter).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Ironman World Championship"))
      result = presenter.current_location
      expect(result).to include("**Ironman World Championship**")
      expect(result).not_to include("racing the")
    end
  end

  describe "#elevation" do
    it "states the elevation when known, otherwise nothing" do
      allow(presenter).to receive(:format_elevation).and_return("1,655 m")
      expect(presenter.elevation).to eq("The elevation is 1,655 m")

      allow(presenter).to receive(:format_elevation).and_return(nil)
      expect(presenter.elevation).to be_nil
    end
  end

  describe "#smooth" do
    it "quips on a hot non-race daytime" do
      allow(presenter).to receive(:is_race_day?).and_return(false)
      allow(presenter).to receive(:is_hot?).and_return(true)
      allow(presenter).to receive(:is_daytime?).and_return(true)
      expect(presenter.smooth).to eq("Man, it's a hot one!")
    end

    it "stays quiet on race day" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_hot?).and_return(true)
      allow(presenter).to receive(:is_daytime?).and_return(true)
      expect(presenter.smooth).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Current conditions / wind / AQI / pollen / forecast / precipitation
  # ---------------------------------------------------------------------------
  describe "#currently" do
    it "summarizes condition, temperature, humidity and wind, hiding a matching feels-like" do
      build_weather(current: { temperature: 18.4, temperature_apparent: 17.9, humidity: 0.55 })
      text = presenter.currently
      expect(text).to include("It's partly cloudy, with a temperature of")
      expect(text).to include("55% humidity")
      expect(text).not_to include("which feels like")
    end

    it "includes the feels-like when it differs" do
      build_weather(current: { temperature: 25.0, temperature_apparent: 30.0 })
      expect(presenter.currently).to include("which feels like")
    end
  end

  describe "#wind" do
    it "describes the Beaufort strength, speed and direction" do
      build_weather(current: { wind_speed: 20.0, wind_direction: 270, wind_gust: 22.0 })
      text = presenter.wind
      expect(text).to include("from the west")
      expect(text).to include("km/h")
    end

    it "is silent when the air is calm" do
      build_weather(current: { wind_speed: 0.0, wind_direction: 270 })
      expect(presenter.wind).to be_nil
    end

    it "mentions gusts when they're notably stronger" do
      build_weather(current: { wind_speed: 15.0, wind_direction: 270, wind_gust: 50.0 })
      expect(presenter.wind).to include("gusts")
    end
  end

  describe "#current_aqi" do
    it "is silent without air quality data" do
      expect(presenter.current_aqi).to be_nil
    end

    it "describes a normal AQI reading" do
      presenter.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 42, category: "Good"))
      expect(presenter.current_aqi).to include("The air quality is good, with an")
      expect(presenter.current_aqi).to include("AQI</abbr> of 42")
    end

    it "flags readings beyond the scale" do
      presenter.instance_variable_set(:@air_quality, DeepOstruct.wrap(aqi: 600, category: "Hazardous"))
      expect(presenter.current_aqi).to include("beyond the")
    end
  end

  describe "#format_pollen_level" do
    it "reports the dominant pollen level" do
      presenter.instance_variable_set(:@pollen, DeepOstruct.wrap(pollen_type_info: [
        { index_info: { value: 1, category: "Low" } },
        { index_info: { value: 3, category: "Moderate" } }
      ]))

      expect(presenter.format_pollen_level).to eq("Pollen levels are moderate")
    end

    it "emits no sentence when pollen is zero/missing" do
      presenter.instance_variable_set(:@pollen, DeepOstruct.wrap(pollen_type_info: [{ index_info: { value: 0, category: "None" } }]))

      expect(presenter.format_pollen_level).to be_nil
    end
  end

  describe "#forecast" do
    it "gives a high and low during the day" do
      build_weather
      allow(presenter).to receive(:is_evening?).and_return(false)
      text = presenter.forecast
      expect(text).to include("Today's forecast is clear")
      expect(text).to include("with a high of")
      expect(text).to include("and a low of")
    end

    it "gives only a low in the evening" do
      build_weather(overnight: { condition_code: "Clear" })
      allow(presenter).to receive(:is_evening?).and_return(true)
      text = presenter.forecast
      expect(text).to include("Tonight's forecast is clear")
      expect(text).to include("with a low of")
      expect(text).not_to include("high of")
    end
  end

  describe "#precipitation" do
    it "is silent when there's no chance, or it's clear" do
      build_weather(rest_of_day: { precipitation_chance: 0, precipitation_type: "clear" })
      expect(presenter.precipitation).to be_nil
    end

    it "states the chance of rain later today" do
      build_weather(rest_of_day: { precipitation_chance: 0.4, precipitation_type: "rain" })
      allow(presenter).to receive(:is_evening?).and_return(false)
      expect(presenter.precipitation).to include("chance of rain later today")
    end

    it "adds an expected amount for snow" do
      build_weather(rest_of_day: { precipitation_chance: 0.5, precipitation_type: "snow", snowfall_amount: 30 })
      allow(presenter).to receive(:is_evening?).and_return(false)
      text = presenter.precipitation
      expect(text).to include("chance of snow")
      expect(text).to include("expected")
    end
  end

  describe "#sunrise_or_sunset" do
    it "counts down to sunrise before it happens" do
      build_weather(sunrise: Time.current + 2.hours, sunset: Time.current + 8.hours)
      expect(presenter.sunrise_or_sunset).to include("Sunrise will be at")
    end

    it "counts down to sunset during the day" do
      build_weather
      expect(presenter.sunrise_or_sunset).to include("Sunset will be at")
    end

    it "counts down to tomorrow's sunrise after sunset" do
      build_weather(sunrise: Time.current - 8.hours, sunset: Time.current - 1.hour)
      expect(presenter.sunrise_or_sunset).to include("Sunrise will be at")
    end
  end

  # ---------------------------------------------------------------------------
  # Activity suggestions
  # ---------------------------------------------------------------------------
  describe "#activities" do
    before do
      allow(presenter).to receive(:is_daytime?).and_return(true)
      allow(presenter).to receive(:is_race_day?).and_return(false)
      allow(presenter).to receive(:is_indoor_season?).and_return(false)
      allow(presenter).to receive(:is_workout_scheduled?).and_return(false)
      allow(presenter).to receive(:is_good_weather?).and_return(true)
      allow(presenter).to receive(:is_hot?).and_return(false)
    end

    it "says nothing at night" do
      allow(presenter).to receive(:is_daytime?).and_return(false)
      expect(presenter.activities).to be_nil
    end

    it "calls the racing weather on race day" do
      allow(presenter).to receive(:is_race_day?).and_return(true)
      expect(presenter.activities).to eq("Good weather for racing!")

      allow(presenter).to receive(:is_good_weather?).and_return(false)
      expect(presenter.activities).to eq("Tough weather for racing!")
    end

    it "suggests indoor training or rest during indoor season" do
      allow(presenter).to receive(:is_indoor_season?).and_return(true)

      allow(presenter).to receive(:is_workout_scheduled?).and_return(true)
      expect(presenter.activities).to eq("It's a good day to train indoors!")

      allow(presenter).to receive(:is_workout_scheduled?).and_return(false)
      expect(presenter.activities).to eq("It's a good day to rest!")
    end

    it "tailors a scheduled workout to the weather" do
      allow(presenter).to receive(:is_workout_scheduled?).and_return(true)

      allow(presenter).to receive(:is_hot?).and_return(true)
      expect(presenter.activities).to eq("It's a good day for some heat training!")

      allow(presenter).to receive(:is_hot?).and_return(false)
      expect(presenter.activities).to eq("It's a good day to train outside!")

      allow(presenter).to receive(:is_good_weather?).and_return(false)
      expect(presenter.activities).to eq("It's a good day to train indoors!")
    end

    it "falls back to outside / rest with no workout scheduled" do
      expect(presenter.activities).to eq("It's a good day to be outside!")

      allow(presenter).to receive(:is_good_weather?).and_return(false)
      expect(presenter.activities).to eq("It's a good day to rest!")
    end
  end

  describe "#is_indoor_season?" do
    it "is true only in Jackson Hole during the winter months" do
      allow(presenter).to receive(:in_jackson_hole?).and_return(true)

      travel_to(Time.now.change(month: 12)) { expect(presenter.is_indoor_season?).to be(true) }
      travel_to(Time.now.change(month: 7)) { expect(presenter.is_indoor_season?).to be(false) }
    end

    it "is false away from Jackson Hole even in winter" do
      allow(presenter).to receive(:in_jackson_hole?).and_return(false)
      travel_to(Time.now.change(month: 12)) { expect(presenter.is_indoor_season?).to be(false) }
    end
  end

  # ---------------------------------------------------------------------------
  # Full summary (integration of the pieces above)
  # ---------------------------------------------------------------------------
  describe "#weather_summary" do
    before do
      build_weather
      allow(presenter).to receive(:is_race_day?).and_return(true)
      allow(presenter).to receive(:is_evening?).and_return(false)
      allow(presenter).to receive(:is_daytime?).and_return(true)
      allow(presenter).to receive(:is_good_weather?).and_return(true)
      allow(presenter).to receive(:is_workout_scheduled?).and_return(false)
      allow(presenter).to receive(:todays_race).and_return(DeepOstruct.wrap(title: "Boston Marathon"))
      allow(presenter).to receive(:format_location).and_return("Boston, Massachusetts")
      allow(presenter).to receive(:format_elevation).and_return("43 m")
    end

    it "stitches the sentences into wrapped HTML spans" do
      html = presenter.weather_summary
      expect(html).to include("<span>")
      expect(html).to include("race day")                # race_day note (smartypants-ified)
      expect(html).to include("Boston, Massachusetts")   # current_location
      expect(html).to include("racing the")              # racing the Boston Marathon
      expect(html).to include("temperature of")          # currently
      expect(html).to include("Good weather for racing!") # activities
    end

    it "omits the race-day note and racing clause off race day" do
      allow(presenter).to receive(:is_race_day?).and_return(false)
      html = presenter.weather_summary
      expect(html).not_to include("race day")
      expect(html).not_to include("racing")
    end
  end
end
