require "rails_helper"

# The tests for the selection methods and the format methods of the weather helper. The text summary
# and its rules moved to WeatherSummaryPresenter (refer to weather_summary_presenter_spec).
#
# Most of the tests make a weather object whose forecast window, sunrise, and sunset are times from
# the current time. Thus they agree with each other and the test does not stop the clock. The
# daytime and evening code with no forecast reads the clock in the given timezone. Thus that test
# stops the clock at a UTC instant and tests against the local hour in Denver.
RSpec.describe WeatherHelper, type: :helper do
  include ActiveSupport::Testing::TimeHelpers

  let(:time_zone) { "America/Denver" }

  # Makes a weather object. `current`, `today`, `rest_of_day`, and `overnight` go into their own
  # sub-hashes. `sunrise` and `sunset` replace the sun times of today.
  def build_weather(current: {}, today: {}, rest_of_day: {}, overnight: {}, sunrise: nil, sunset: nil, alerts: [])
    now = Time.current
    DeepOstruct.wrap(
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
  end

  # ---------------------------------------------------------------------------
  # The condition phrases
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
  # The number format and the unit format
  # ---------------------------------------------------------------------------
  # ⚠️ WeatherKit omits a field at times, and a nil here gave the full widget a 500.
  describe "nil fields" do
    it "gives nil, and does not raise, for a condition, an amount, or a type that is absent" do
      expect(helper.format_forecasted_condition(nil)).to be_nil
      expect(helper.format_condition(nil)).to be_nil
      expect(helper.format_precipitation_amount(nil)).to be_nil
      expect(helper.format_precipitation_type(nil)).to be_nil
    end
  end

  describe "#format_temperature" do
    it "renders both Celsius and Fahrenheit with the unit toggle" do
      html = helper.format_temperature(18.0)
      expect(html).to include("18°C")
      expect(html).to include('data-units-imperial-value="64°F"')
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
      expect(helper.format_time(time)).to include("9:05&nbsp;<abbr title=\"ante meridiem\">AM</abbr>")
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
    it "puts a fraction between two bands in the lower band" do
      expect(helper.aqi_icon(50.5)).to eq("smog")
      expect(helper.aqi_icon(150.4)).to eq("smoke")
    end

    it "picks an icon by AQI band" do
      expect(helper.aqi_icon(30)).to eq("sun-haze")
      expect(helper.aqi_icon(100)).to eq("smog")
      expect(helper.aqi_icon(175)).to eq("smoke")
      expect(helper.aqi_icon(300)).to eq("fire-smoke")
    end
  end

  # ---------------------------------------------------------------------------
  # The pollen
  # ---------------------------------------------------------------------------
  describe "pollen" do
    it "reports the highest non-zero index and its category" do
      pollen = DeepOstruct.wrap(pollen_type_info: [
        { index_info: { value: 1, category: "Low" } },
        { index_info: { value: 3, category: "Moderate" } }
      ])

      expect(helper.pollen_index_value(pollen)).to eq(3)
      expect(helper.pollen_index_category(pollen)).to eq("Moderate")
    end

    it "treats all-zero (or missing) pollen as None" do
      pollen = DeepOstruct.wrap(pollen_type_info: [ { index_info: { value: 0, category: "None" } } ])

      expect(helper.pollen_index_value(pollen)).to eq(0)
      expect(helper.pollen_index_category(pollen)).to eq("None")
    end
  end

  # ---------------------------------------------------------------------------
  # The availability of the weather data
  # ---------------------------------------------------------------------------
  describe "weather data presence" do
    it "exposes current weather and today's forecast and reports currency" do
      weather = build_weather
      expect(helper.current_weather(weather).condition_code).to eq("PartlyCloudy")
      expect(helper.todays_forecast(weather).temperature_max).to eq(24.0)
      expect(helper.weather_data_is_current?(weather, time_zone)).to be(true)
      expect(helper.weather_data_is_stale?(weather, time_zone)).to be(false)
    end

    it "is stale when there's no weather" do
      expect(helper.weather_data_is_current?(nil, time_zone)).to be(false)
      expect(helper.weather_data_is_stale?(nil, time_zone)).to be(true)
    end

    it "returns the daytime forecast during the day and the overnight one in the evening" do
      weather = build_weather(rest_of_day: { condition_code: "Rain" }, overnight: { condition_code: "Cloudy" })

      allow(helper).to receive(:evening?).and_return(false)
      expect(helper.rest_of_day_forecast(weather, time_zone).condition_code).to eq("Rain")

      allow(helper).to receive(:evening?).and_return(true)
      expect(helper.rest_of_day_forecast(weather, time_zone).condition_code).to eq("Cloudy")
    end

    it "finds tomorrow's forecast" do
      expect(helper.tomorrows_forecast(build_weather).temperature_max).to eq(22.0)
    end
  end

  # ---------------------------------------------------------------------------
  # The time of day
  # ---------------------------------------------------------------------------
  describe "#daytime? / #evening?" do
    it "is daytime between sunrise and sunset" do
      weather = build_weather # sunrise 5h ago, sunset in 5h
      expect(helper.daytime?(weather, time_zone)).to be(true)
      expect(helper.evening?(weather, time_zone)).to be(false)
    end

    it "is evening (and not daytime) once the sun has set" do
      weather = build_weather(sunset: Time.current - 1.hour)
      expect(helper.daytime?(weather, time_zone)).to be(false)
      expect(helper.evening?(weather, time_zone)).to be(true)
    end

    it "falls back to clock hours in the given timezone when there's no weather" do
      # The timezone is America/Denver, which is UTC-6 in June. Thus the code reads the local hour
      # in Denver, and not the hour of the machine. 18:00 UTC is 12:00 MDT, which is daytime.
      travel_to(Time.utc(2026, 6, 3, 18, 0, 0)) do
        expect(helper.daytime?(nil, time_zone)).to be(true)
        expect(helper.evening?(nil, time_zone)).to be(false)
      end

      # 04:00 UTC is 22:00 MDT, which is the evening of the previous day.
      travel_to(Time.utc(2026, 6, 4, 4, 0, 0)) do
        expect(helper.daytime?(nil, time_zone)).to be(false)
        expect(helper.evening?(nil, time_zone)).to be(true)
      end
    end

    it "says Today during the day and Tonight in the evening" do
      expect(helper.today_or_tonight(build_weather, time_zone)).to eq("Today")

      weather = build_weather(sunset: Time.current - 1.hour)
      expect(helper.today_or_tonight(weather, time_zone)).to eq("Tonight")
    end
  end

  describe "#sunrise / #sunset / #tomorrows_sunrise" do
    it "returns zoned times from the forecast" do
      weather = build_weather
      expect(helper.sunrise(weather, time_zone)).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.sunset(weather, time_zone)).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.tomorrows_sunrise(weather, time_zone)).to be_a(ActiveSupport::TimeWithZone)
      expect(helper.tomorrows_sunrise(weather, time_zone)).to be > helper.sunrise(weather, time_zone)
    end
  end

  # ---------------------------------------------------------------------------
  # The icon and the alerts
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
      allow(helper).to receive(:daytime?).and_return(true)
      expect(helper.weather_icon("Clear", :auto)).to eq("sun")
      allow(helper).to receive(:daytime?).and_return(false)
      expect(helper.weather_icon("Clear", :auto)).to eq("moon-stars")
    end

    it "falls back to a question-mark cloud for unknown conditions" do
      expect(helper.weather_icon("Nonsense")).to eq("cloud-question")
    end
  end

  describe "#weather_alerts" do
    it "is empty without alerts" do
      expect(helper.weather_alerts(build_weather)).to eq([])
    end

    it "keeps the lowest-precedence alert per token, sorted by precedence" do
      weather = build_weather(alerts: [
        { token: "flood", precedence: 3, description: "Flood B" },
        { token: "flood", precedence: 1, description: "Flood A" },
        { token: "heat", precedence: 5, description: "Heat" }
      ])

      alerts = helper.weather_alerts(weather)
      expect(alerts.map(&:description)).to eq([ "Flood A", "Heat" ])
    end
  end
end
