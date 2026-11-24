require "rails_helper"

# The tests for the selection of the weather data: the forecast of today, the sun times, the time
# of day, and the alerts.
#
# Most of the tests make a weather object whose forecast window, sunrise, and sunset are times from
# the current time. Thus they agree with each other and the test does not stop the clock. The
# daytime and evening code with no forecast reads the clock in the given timezone. Thus that test
# stops the clock at a UTC instant and tests against the local hour in Denver.
RSpec.describe Forecast do
  include ActiveSupport::Testing::TimeHelpers

  let(:time_zone) { "America/Denver" }

  def forecast(weather) = described_class.new(weather, time_zone)

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

  describe "the availability of the data" do
    it "gives the weather now and the forecast of today, and says that the data is current" do
      subject = forecast(build_weather)

      expect(subject.current.condition_code).to eq("PartlyCloudy")
      expect(subject.today.temperature_max).to eq(24.0)
      expect(subject).to be_current
    end

    it "is not current with no weather" do
      expect(forecast(nil)).not_to be_current
    end

    it "gives the forecast of the rest of the day, and the overnight one in the evening" do
      weather = build_weather(rest_of_day: { condition_code: "Rain" }, overnight: { condition_code: "Cloudy" })

      day = forecast(weather)
      allow(day).to receive(:evening?).and_return(false)
      expect(day.rest_of_day.condition_code).to eq("Rain")

      evening = forecast(weather)
      allow(evening).to receive(:evening?).and_return(true)
      expect(evening.rest_of_day.condition_code).to eq("Cloudy")
    end

    it "finds the forecast of tomorrow" do
      expect(forecast(build_weather).tomorrow.temperature_max).to eq(22.0)
    end

    # ⚠️ The controller reads #current? before its `safely` blocks, thus a raise here is a 500 on
    # the widget.
    it "is not current, and does not raise, when a forecast time is absent or broken" do
      weather = build_weather
      weather.forecast_daily.days.first.forecast_start = nil
      weather.forecast_daily.days.last.forecast_start = "not a time"

      expect(forecast(weather)).not_to be_current
      expect(forecast(weather).tomorrow).to be_nil
    end
  end

  describe "the time of day" do
    it "is daytime between the sunrise and the sunset" do
      subject = forecast(build_weather) # The sunrise was 5 hours ago, and the sunset is in 5 hours.

      expect(subject).to be_daytime
      expect(subject).not_to be_evening
    end

    it "is evening, and not daytime, after the sunset" do
      subject = forecast(build_weather(sunset: Time.current - 1.hour))

      expect(subject).not_to be_daytime
      expect(subject).to be_evening
    end

    it "uses the clock in the given timezone with no weather" do
      # The timezone is America/Denver, which is UTC-6 in June. Thus the code reads the local hour
      # in Denver, and not the hour of the machine. 18:00 UTC is 12:00 MDT, which is daytime.
      travel_to(Time.utc(2026, 6, 3, 18, 0, 0)) do
        expect(forecast(nil)).to be_daytime
        expect(forecast(nil)).not_to be_evening
      end

      # 04:00 UTC is 22:00 MDT, which is the evening of the previous day.
      travel_to(Time.utc(2026, 6, 4, 4, 0, 0)) do
        expect(forecast(nil)).not_to be_daytime
        expect(forecast(nil)).to be_evening
      end
    end

    it "says Today during the day and Tonight in the evening" do
      expect(forecast(build_weather).today_or_tonight).to eq("Today")
      expect(forecast(build_weather(sunset: Time.current - 1.hour)).today_or_tonight).to eq("Tonight")
    end
  end

  describe "the sun times" do
    it "gives each one as a time in the timezone" do
      subject = forecast(build_weather)

      expect(subject.sunrise).to be_a(ActiveSupport::TimeWithZone)
      expect(subject.sunset).to be_a(ActiveSupport::TimeWithZone)
      expect(subject.tomorrows_sunrise).to be_a(ActiveSupport::TimeWithZone)
      expect(subject.tomorrows_sunrise).to be > subject.sunrise
    end
  end

  describe "#alerts" do
    it "is empty with no alerts" do
      expect(forecast(build_weather).alerts).to eq([])
    end

    it "keeps the alert with the lowest precedence of each token, in order of precedence" do
      weather = build_weather(alerts: [
        { token: "flood", precedence: 3, description: "Flood B" },
        { token: "flood", precedence: 1, description: "Flood A" },
        { token: "heat", precedence: 5, description: "Heat" }
      ])

      expect(forecast(weather).alerts.map(&:description)).to eq([ "Flood A", "Heat" ])
    end
  end
end
