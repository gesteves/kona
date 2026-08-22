require "rails_helper"

RSpec.describe BayHelper do
  let(:bay_helper) { Class.new { include BayHelper }.new }

  let(:target) { Time.utc(2024, 6, 1, 12, 0, 0) }

  describe "#bay_conditions_at" do
    it "returns the timeseries entry closest to the given time" do
      goodspeed = DeepOstruct.wrap(timeseries: [
        { t: (target - 300).iso8601,  current_speed_kt: 1.0 },
        { t: (target - 2400).iso8601, current_speed_kt: 0.1 }
      ])
      expect(bay_helper.bay_conditions_at(goodspeed, target).current_speed_kt).to eq(1.0)
    end

    it "returns nil when the closest entry is outside the freshness window" do
      goodspeed = DeepOstruct.wrap(timeseries: [ { t: (target - 2400).iso8601, current_speed_kt: 0.1 } ])
      expect(bay_helper.bay_conditions_at(goodspeed, target)).to be_nil
    end

    it "returns nil when there's no bay data" do
      expect(bay_helper.bay_conditions_at(nil, target)).to be_nil
    end
  end

  describe "#bay_current_state" do
    def state_for(speed:, bearing:)
      bay_helper.bay_current_state(DeepOstruct.wrap(current_speed_kt: speed, current_bearing_deg: bearing))
    end

    it "is slack below the slack-current threshold" do
      expect(state_for(speed: 0.1, bearing: 110)).to eq(:slack)
    end

    it "is flood when the current sets toward the flood bearing" do
      expect(state_for(speed: 1.0, bearing: 110)).to eq(:flood)
    end

    it "is ebb when the current sets opposite the flood bearing" do
      expect(state_for(speed: 1.0, bearing: 290)).to eq(:ebb)
    end
  end

  describe "#format_bay_current_speed" do
    it "converts m/s to km/h and reuses the wind-speed unit toggle" do
      # 5 m/s is 18 km/h. format_wind_speed needs the view helpers, thus this uses a helper
      # context.
      html = Class.new do
        include ActionView::Helpers::TagHelper
        include UnitsHelper
        include MarkupHelper
        include WeatherHelper
        include BayHelper
      end.new.format_bay_current_speed(5.0)
      expect(html).to include("18 km/h")
    end
  end
end

# bay_water_temperature_sentence calls other helpers, that is, in_san_francisco? and
# format_temperature. Thus these tests use a full helper context, where those methods are
# available.
RSpec.describe BayHelper, "#bay_water_temperature_sentence", type: :helper do
  let(:location) { double("location") }

  it "is nil away from San Francisco" do
    allow(helper).to receive(:in_san_francisco?).with(location).and_return(false)
    expect(helper.bay_water_temperature_sentence(nil, location)).to be_nil
  end

  it "is nil in San Francisco when there's no recent bay reading" do
    allow(helper).to receive(:in_san_francisco?).with(location).and_return(true)
    expect(helper.bay_water_temperature_sentence(nil, location)).to be_nil
  end

  it "states the water temperature in San Francisco when a recent reading exists" do
    allow(helper).to receive(:in_san_francisco?).with(location).and_return(true)
    goodspeed = DeepOstruct.wrap(timeseries: [
      { t: Time.now.iso8601, water_temp_c: 15.0, current_speed_kt: 0.5, current_bearing_deg: 110 }
    ])

    sentence = helper.bay_water_temperature_sentence(goodspeed, location)
    expect(sentence).to include("The water temperature in San Francisco Bay is")
    expect(sentence).to include("15°C")
  end
end
