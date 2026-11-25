require "rails_helper"

RSpec.describe ActivityDescription::IntervalsWeather do
  # @param activity [Hash] The activity, as a Hash or as keywords.
  def weather(activity = {}, intervals: nil, **fields)
    described_class.new(activity.merge(fields), intervals: intervals)
  end

  it "is available only with the weather flag and both temperatures" do
    expect(weather(has_weather: true, min_weather_temp: 0, max_weather_temp: 5)).to be_available
    expect(weather(min_weather_temp: 0, max_weather_temp: 5)).not_to be_available
    expect(weather(has_weather: true, min_weather_temp: 0)).not_to be_available
  end

  it "takes the condition from the precipitation, then from the cloud cover" do
    expect(weather(max_rain: 1, max_snow: 1).condition_code).to eq("MixedRainAndSnow")
    expect(weather(max_snow: 0.5).condition_code).to eq("Snow")
    expect(weather(max_rain: 0, max_showers: 0.2).condition_code).to eq("Rain")
    expect(weather(average_clouds: 50).condition_code).to eq("PartlyCloudy")
    expect(weather({}).condition_code).to eq("Clear")
  end

  it "gives the temperatures as they are" do
    activity = { min_weather_temp: 3, max_weather_temp: 9, min_feels_like: 1 }

    expect(weather(activity).temperatures).to eq([ 3, 9 ])
    expect(weather(activity).feels_like).to eq([ 1, nil ])
  end

  it "gives the wind in km/h, and the average with no range" do
    expect(weather(min_wind_speed: 1, max_wind_speed: 10, average_wind_speed: 5).wind_speeds_kph).to eq([ 3.6, 36.0 ])
    expect(weather(average_wind_speed: 5).wind_speeds_kph).to eq([ 18.0, 18.0 ])
    expect(weather({}).wind_speeds_kph).to be_nil
    expect(weather(average_wind_speed: 5).mean_wind_kph).to eq(18.0)
  end

  it "gives the highest gust, or the average gust with no highest one" do
    expect(weather(max_wind_gust: 20, average_wind_gust: 10).gust_kph).to eq(72.0)
    expect(weather(average_wind_gust: 10).gust_kph).to eq(36.0)
    expect(weather({}).gust_kph).to eq(0.0)
  end

  it "rounds the headwind share" do
    expect(weather(headwind_percent: 61.6).headwind_percent).to eq(62)
    expect(weather({}).headwind_percent).to be_nil
  end

  it "puts the full weather summary of Intervals.icu over the activity, with one request" do
    intervals = double("Intervals", activity_weather_summary: { max_showers: 0.3, prevailing_wind_deg: 270, average_clouds: nil })
    subject = weather({ id: 7, average_clouds: 90 }, intervals: intervals)

    expect(subject.condition_code).to eq("Rain")
    expect(subject.wind_degrees).to eq(270)
    expect(intervals).to have_received(:activity_weather_summary).with(7).once
  end

  it "makes no request for an activity with no id" do
    intervals = double("Intervals", activity_weather_summary: {})

    expect(weather({ average_clouds: 90 }, intervals: intervals).condition_code).to eq("Cloudy")
    expect(intervals).not_to have_received(:activity_weather_summary)
  end
end
