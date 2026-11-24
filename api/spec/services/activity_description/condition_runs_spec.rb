require "rails_helper"

RSpec.describe ActivityDescription::ConditionRuns do
  # One sample for each minute of each stretch, as [code, minutes] or [code, minutes, daylight].
  def runs(*stretches)
    offset = -60
    samples = stretches.flat_map do |code, minutes, daylight|
      Array.new(minutes) do
        { offset: offset += 60, seconds: 60.0, weather: { conditionCode: code, daylight: daylight != false } }
      end
    end
    described_class.new(samples)
  end

  describe "#main" do
    it "is nil with no samples" do
      expect(runs.main).to be_nil
    end

    it "is the code with the most time in the sky family with the most time" do
      expect(runs([ "Clear", 30 ], [ "MostlyClear", 25 ], [ "PartlyCloudy", 45 ]).main).to eq(code: "Clear", daylight: true)
    end

    it "says when most of that time was at night" do
      expect(runs([ "Clear", 40, false ]).main).to eq(code: "Clear", daylight: false)
    end

    it "joins a run shorter than 15 minutes to its neighbor" do
      expect(runs([ "Clear", 60 ], [ "Rain", 10 ], [ "Clear", 60 ]).precipitation_spell).to be_nil
      expect(runs([ "Rain", 10 ], [ "Clear", 60 ]).main).to eq(code: "Clear", daylight: true)
    end
  end

  describe "#precipitation_spell" do
    it "names the precipitation of another type than the main condition" do
      expect(runs([ "Cloudy", 60 ], [ "Rain", 20 ]).precipitation_spell).to eq(condition: "rain")
    end

    it "is nil for precipitation of the same type as the main condition" do
      expect(runs([ "Rain", 60 ], [ "Drizzle", 20 ]).precipitation_spell).to be_nil
    end
  end

  describe "#facts" do
    it "gives the precipitation, the wind, and the sky, in that order" do
      facts = runs([ "Cloudy", 60 ], [ "Rain", 20 ]).facts(wind_kph: 25.0, cloud_cover: nil)

      expect(facts).to eq([ [ "Precipitation", "rain, part of the time" ], [ "Wind", "windy" ], [ "Sky", "cloudy" ] ])
    end

    it "says when the precipitation stopped and started again, and omits the sky below it" do
      facts = runs([ "Rain", 20 ], [ "Cloudy", 20 ], [ "Rain", 20 ]).facts(wind_kph: 5.0, cloud_cover: nil)

      expect(facts).to eq([ [ "Precipitation", "rain, most of the time, on and off" ] ])
    end

    it "gives the sky alone for a calm and dry activity" do
      expect(runs([ "Clear", 60 ]).facts(wind_kph: 5.0, cloud_cover: 0.0)).to eq([ [ "Sky", "clear" ] ])
    end

    it "takes the sky from the cloud cover when no run has a sky code" do
      facts = runs([ "Windy", 60 ]).facts(wind_kph: 30.0, cloud_cover: 0.5)

      expect(facts).to eq([ [ "Wind", "very windy" ], [ "Sky", "partly cloudy" ] ])
    end

    it "gives no facts with a code that config/conditions.yml does not have" do
      expect(runs([ "SomethingNew", 60 ]).facts(wind_kph: 30.0, cloud_cover: 0.5)).to eq([])
    end

    it "gives no facts with no samples" do
      expect(runs.facts(wind_kph: 30.0, cloud_cover: 0.5)).to eq([])
    end
  end
end
